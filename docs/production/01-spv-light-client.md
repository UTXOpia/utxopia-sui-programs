# 01 — Bitcoin SPV Light Client (Move)

Production-hardening spec for UTXOpia on Sui. Module set: `spv-light-client`.

Status: implementation-ready. Do not re-derive design from this doc; implement it.

---

## 1. Goal & What This Replaces

Build a **real, trustless Bitcoin light client in Move** that mirrors the Solana
`btc-light-client` program. It must:

1. Store a header chain (per-block: parent hash, merkle root, bits, timestamp,
   block hash, cumulative chainwork, height).
2. Track the canonical tip (hash, height, total chainwork) and a finalized height.
3. Validate submitted headers: double-SHA256 PoW vs `bits` target, `bits`-matches-
   expected difficulty, chain continuity (`prev_hash`), and 2016-block difficulty
   retarget with the `[timespan/4, timespan*4]` clamp.
4. Handle reorgs by **longest cumulative chainwork**, re-pointing a canonical
   height→hash index when a heavier fork is submitted.
5. Expose a read API that `complete_deposit` (deposit SPV → commitment) consumes to
   check confirmations and look up a block's merkle root.

### Current stub being replaced

- `chains/sui/contracts/sources/btc_light_client.move:16-40`
  `new_verified_deposit(...)` does **ZERO verification** — only length asserts on
  txid/op_return/commitment/root. Anyone who can build a `VerifiedBtcDeposit` mints
  an arbitrary deposit. This is the critical hole.
- `chains/sui/scripts/regtest-flow.ts:210` already flags that the E2E "create this
  object with the production Sui SPV verifier before running the flow."

This module provides the on-chain machinery so that `VerifiedBtcDeposit` can only be
minted from a header that is on the canonical chain with ≥ `REQUIRED_CONFIRMATIONS`,
and a tx merkle-included in that header. The actual `VerifiedBtcDeposit` construction
(OP_RETURN parse, amount extraction, commitment hashing) lives in the **`btc-deposit`**
sibling module (separate spec); this module supplies the verified-inclusion primitive
and a `BlockHeaderRecord` lookup.

### Solana reference being ported (source of truth)

| Concern | Solana file |
|---|---|
| LC state layout | `contracts/programs/btc-light-client/src/state/light_client.rs` |
| Header record layout | `.../state/block_header.rs` |
| Height index | `.../state/height_index.rs` |
| Verified tx record | `.../state/verified_transaction.rs` |
| Header submit/validate/reorg | `.../instructions/extend_blockchain.rs` |
| Tx inclusion proof | `.../instructions/verify_transaction.rs` |
| PoW + target + chainwork | `.../utils/pow.rs` |
| Retarget | `.../utils/difficulty.rs` |
| 256-bit math | `.../utils/u256.rs` |
| double-SHA256 | `.../utils/sha256.rs` |
| Confirmation check consumer | `contracts/programs/utxopia/src/instructions/complete_deposit.rs:262-274` |
| Constants | `.../btc-light-client/src/constants.rs` |

---

## 2. Sui-Native Data Model

### 2.1 Object-model divergence from Solana PDAs

| Solana (PDA) | Sui equivalent | Notes |
|---|---|---|
| `BitcoinLightClient` PDA (1 per program) | `LightClient` **shared object** | Single shared object; mutated by permissionless `submit_headers`. |
| `BlockHeader` PDA `["block", hash]` | **dynamic field** on `LightClient`, key = block hash (`vector<u8>` / `u256`) | No address derivation; key is the hash itself. O(1) lookup, no rent, but storage grows. |
| `HeightIndex` PDA `["height_index", height]` | **dynamic field** on `LightClient`, key = `u64` height | Re-pointed on reorg by overwriting the dynamic-field value. |
| `VerifiedTransaction` PDA `["verified_tx", block, txid]` | **NOT a stored object** — see §5.4 | Sui can hand back a hot-potato/struct in the same PTB; we do not persist a per-tx object. The `btc-deposit` module consumes it immediately. |
| genesis bootstrap by authority | `AdminCap` (already exists in `pool.move:11`) gated `initialize` | Pattern matches existing `pool::AdminCap`. |

Key Sui wins to exploit:
- **Native `u256`.** Chainwork, targets, and target arithmetic use `u256` directly.
  This deletes the entire `utils/u256.rs` 4×u64 limb library (`u256_add/div/mul/clz/
  shl/sub`) and `pow.rs::add_chainwork`. Chainwork compare is `>` on `u256`.
- **`sui::hash::sha2_256(vector<u8>): vector<u8>`** is a native; double-SHA256 is two
  calls. Matches `sha256.rs` semantics (the Solana non-`os=solana` fallback is a fake
  XOR hash for `cargo check` only — ignore it).

### 2.2 Structs / objects

```move
module utxopia::btc_light_client {

    /// Shared singleton. One per deployment.
    public struct LightClient has key {
        id: UID,
        network: u8,              // 0 = mainnet, 1 = testnet3 reserved, 2 = testnet4 reserved, 3 = regtest
        paused: bool,
        // canonical tip
        tip_hash: vector<u8>,     // 32 bytes, internal byte order (NOT reversed)
        tip_height: u64,
        total_chainwork: u256,    // cumulative work of canonical chain to tip
        finalized_height: u64,    // tip_height - REQUIRED_CONFIRMATIONS (saturating)
        // difficulty tracking for the *canonical* chain
        expected_bits: u32,       // bits every block in current epoch must use
        epoch_start_time: u32,    // timestamp of first block of current epoch
        // bookkeeping
        genesis_hash: vector<u8>, // 32 bytes; immutable anchor
        header_count: u64,        // total stored headers (all forks)
        last_update_ms: u64,      // from Clock
        // dynamic fields hang off `id`:
        //   df key Hash(hash:vector<u8>)  -> HeaderRecord
        //   df key Height(h:u64)          -> vector<u8> (canonical hash at h)
        //   df key Pruned -> PruneState (see §6)
    }

    /// Stored per accepted header (canonical OR side fork).
    public struct HeaderRecord has store, copy, drop {
        version: u32,
        prev_hash: vector<u8>,    // 32 bytes
        merkle_root: vector<u8>,  // 32 bytes, internal byte order
        timestamp: u32,
        bits: u32,
        nonce: u32,
        block_hash: vector<u8>,   // 32 bytes, internal byte order
        chainwork: u256,          // cumulative work up to & including this block
        height: u64,
        // difficulty params *as of this block* (needed to validate children of a fork)
        expected_bits: u32,
        epoch_start_time: u32,
    }

    /// Dynamic-field key wrappers (typed keys avoid collisions).
    public struct HashKey   has copy, drop, store { hash: vector<u8> }
    public struct HeightKey has copy, drop, store { height: u64 }

    /// Returned (hot potato style, no `key`/`store`) by verify_tx_inclusion so the
    /// caller MUST consume it in the same PTB. Proves: txid included in a canonical,
    /// sufficiently-confirmed block. The btc-deposit module unpacks it.
    public struct VerifiedInclusion {
        txid: vector<u8>,         // 32 bytes, internal byte order
        block_hash: vector<u8>,
        block_height: u64,
        merkle_root: vector<u8>,
        tx_index: u32,
    }
}
```

Notes:
- `VerifiedInclusion` has **no abilities** → it is a hot potato. The only consumer is
  `utxopia::btc_deposit` via a `public(package)` unpack fn. This is the Sui-native
  replacement for the persisted `VerifiedTransaction` PDA and the
  `complete_deposit.rs` cross-program `VerifiedTransaction` read.
- `HeaderRecord` carries `expected_bits` / `epoch_start_time` so a fork submitted from
  an old parent re-derives difficulty from the **parent's** state, not the global tip's.
  Solana carried these only on the global LC and `extend_blockchain.rs:128-134`
  explicitly punts on fork-from-old-epoch ("for simplicity, we carry forward from
  parent"). We FIX this divergence — see §7 risk R4.

---

## 3. Function Signatures

### 3.1 Entry / public

```move
/// Bootstrap. Authority anchors a trusted genesis (a checkpoint header, NOT block 0,
/// to keep the chain short). Stores it as height H0 with a starting chainwork.
public fun initialize(
    _: &AdminCap,                 // reuse pool::AdminCap or a dedicated LightClientAdminCap
    network: u8,
    genesis_raw_header: vector<u8>,   // 80 bytes
    genesis_height: u64,
    genesis_chainwork: u256,          // trusted cumulative work at the checkpoint
    genesis_expected_bits: u32,       // bits the next epoch enforces
    genesis_epoch_start_time: u32,    // epoch anchor timestamp
    ctx: &mut TxContext,
)

/// Permissionless. Submit 1..=MAX_BATCH_SIZE consecutive headers building on an
/// EXISTING stored parent (canonical tip OR any stored fork block).
/// raw_headers: concatenated 80-byte headers. The first header's prev_hash must
/// equal an existing stored header's block_hash.
public fun submit_headers(
    lc: &mut LightClient,
    raw_headers: vector<u8>,      // N * 80 bytes
    clock: &Clock,
)

/// Admin pause (mirrors pool::set_paused, btc-light-client `paused` flag).
public fun set_paused(_: &AdminCap, lc: &mut LightClient, paused: bool)

/// Read-only confirmations for a canonical block hash. Returns 0 if not canonical.
public fun confirmations(lc: &LightClient, block_hash: vector<u8>): u64

/// Verify tx inclusion against a CANONICAL, confirmed block. Aborts on failure.
/// Returns a hot-potato VerifiedInclusion consumed by btc_deposit in the same PTB.
public fun verify_tx_inclusion(
    lc: &LightClient,
    block_hash: vector<u8>,       // 32 bytes
    txid: vector<u8>,             // 32 bytes, internal byte order (double-SHA256 of raw tx)
    tx_index: u32,
    merkle_siblings: vector<vector<u8>>, // each 32 bytes, leaf→root order
    path_bits: u64,               // bit i set => sibling i is on the LEFT (current is right)
): VerifiedInclusion

/// Package-only unpack for btc_deposit.
public(package) fun consume_inclusion(v: VerifiedInclusion)
    : (vector<u8> /*txid*/, vector<u8> /*block_hash*/, u64 /*height*/,
       vector<u8> /*merkle_root*/, u32 /*tx_index*/)
```

### 3.2 Internal (`fun` / `public(package) fun` for unit tests)

```move
fun double_sha256(data: &vector<u8>): vector<u8>                 // sui::hash::sha2_256 x2
fun double_sha256_pair(left: &vector<u8>, right: &vector<u8>): vector<u8>
fun block_hash_of(raw_header: &vector<u8>): vector<u8>           // double_sha256(80 bytes)

fun target_from_bits(bits: u32): u256                           // port pow.rs:17-34
fun bits_from_target(target: u256): u32                         // port difficulty.rs:43-75
fun work_from_bits(bits: u32): u256                             // 2^256/(target+1), pow.rs:38-70
fun hash_meets_target(hash: &vector<u8>, target: u256): bool    // pow.rs:4-14 (LE compare)
fun calculate_new_bits(old_bits: u32, actual_timespan: u32): u32 // difficulty.rs:10-40

fun parse_header(raw: &vector<u8>): HeaderRecord                // slices 80 bytes, no chainwork/height yet
fun get_header(lc: &LightClient, hash: &vector<u8>): &HeaderRecord
fun has_header(lc: &LightClient, hash: &vector<u8>): bool
fun set_canonical_height(lc: &mut LightClient, height: u64, hash: vector<u8>)
fun canonical_hash_at(lc: &LightClient, height: u64): vector<u8>

// u256 <-> 32-byte LE helpers for hash/target comparison (Bitcoin targets are LE).
fun u256_to_le_bytes(v: u256): vector<u8>
fun le_bytes_to_u256(b: &vector<u8>): u256
```

---

## 4. Algorithm (step-by-step, porting `extend_blockchain.rs`)

### 4.1 `submit_headers` (mirrors `extend_blockchain.rs:35-341`)

1. **Validate args.** `lc.paused == false`. `len(raw_headers) % 80 == 0`,
   `n = len/80`, `1 <= n <= MAX_BATCH_SIZE` (=10). (Ports `:40-53`.)
2. **Resolve parent.** Read `first.prev_hash` (bytes `[4..36]` of header 0). Require
   `has_header(lc, first.prev_hash)`. Read parent `HeaderRecord` → `(parent_height,
   parent_chainwork, parent_hash, parent_expected_bits, parent_epoch_start)`.
   (Ports `:74-120`; Sui replaces "verify parent PDA address" with a dynamic-field
   existence check — no `find_program_address`.)
3. **Init running state from PARENT** (not global tip — this is the fork-correctness
   fix, §7 R4): `prev_hash=parent_hash`, `running_chainwork=parent_chainwork`,
   `running_height=parent_height`, `running_expected_bits=parent_expected_bits`,
   `running_epoch_start=parent_epoch_start`.
4. **For each header i in 0..n** (ports `:137-238`):
   a. Slice 80 bytes. Extract `prev_hash_i = bytes[4..36]`, `bits = u32_le(bytes[72..76])`,
      `timestamp = u32_le(bytes[68..72])`.
   b. **Continuity:** `assert!(prev_hash_i == prev_hash, E_HEADER_PREV_MISMATCH)`. (`:144-147`)
   c. `block_hash = double_sha256(raw_header)`. `block_height = running_height + 1`.
   d. **PoW (skip on regtest):** if `network != REGTEST`:
      - `target = target_from_bits(bits)`; `assert!(hash_meets_target(&block_hash,
        target), E_POW_NOT_MET)`. (`:153-157`)
      - **Difficulty enforcement:** `assert!(running_expected_bits == 0 || bits ==
        running_expected_bits, E_BAD_BITS)`. (`:159-161`)
   e. **Idempotency:** if `has_header(lc, block_hash)` already → skip the store but
      still advance running state (so a re-submitted batch is a no-op). (`:178-204`
      handles this with "account_exists".)
   f. **Chainwork:** `block_work = work_from_bits(bits)`; `new_chainwork =
      running_chainwork + block_work` (native `u256` add; replaces `add_chainwork`).
   g. **Retarget at epoch boundary:** if `network != REGTEST && block_height %
      BLOCKS_PER_EPOCH == 0`: if `running_epoch_start != 0 && running_expected_bits
      != 0`: `actual = timestamp.wrapping_sub(running_epoch_start)` (use checked u32
      wrap semantics — see R6); `running_expected_bits = calculate_new_bits(
      running_expected_bits, actual)`. Then `running_epoch_start = timestamp`.
      (Ports `:225-233`. Note Bitcoin Core's off-by-one: the new bits apply to the
      block AT the boundary's child; we apply at boundary block exactly as Solana
      does — keep behavior identical to Solana for parity. See R7.)
   h. **Store** `HeaderRecord { version, prev_hash, merkle_root=bytes[36..68],
      timestamp, bits, nonce=u32_le(bytes[76..80]), block_hash, chainwork=
      new_chainwork, height=block_height, expected_bits=running_expected_bits,
      epoch_start_time=running_epoch_start }` as dynamic field `HashKey{block_hash}`.
      (Ports `:206-223`.)
   i. Advance: `prev_hash=block_hash; running_chainwork=new_chainwork;
      running_height=block_height`.
5. **Canonical decision (reorg):** `is_new_canonical = running_chainwork >
   lc.total_chainwork` (strict `>`, native `u256`). (Ports `:240-245`,
   `u256_gt_limbs`.) Ties keep the incumbent (first-seen wins) — matches Solana.
6. **If canonical** (ports `:247-329`):
   - Re-point height index: for i in 0..n, `set_canonical_height(lc, parent_height+1+i,
     hash_i)`. Overwrites any previous canonical hash at those heights (the reorg).
   - **Walk-back disconnect of the displaced branch is NOT required** because lookups
     go height→hash→record and `confirmations`/`verify_tx_inclusion` re-validate that
     the height index points at the supplied block. Stale side-branch headers remain
     stored but are unreachable as canonical. (See R3 for the deeper-reorg height
     index correctness argument.)
   - Update `lc.tip_hash=prev_hash`, `lc.tip_height=running_height`,
     `lc.total_chainwork=running_chainwork`, `lc.header_count += n_newly_stored`,
     `lc.finalized_height = saturating_sub(running_height, REQUIRED_CONFIRMATIONS)`,
     and (if not regtest) `lc.expected_bits=running_expected_bits`,
     `lc.epoch_start_time=running_epoch_start`, `lc.last_update_ms=clock.timestamp_ms()`.
7. **Else (non-canonical fork):** store headers (already done in step 4) but DO NOT
   touch tip or height index. Bump `header_count`, set `last_update_ms`. (`:330-338`.)
8. Emit `HeadersSubmitted { new_tip_hash, new_tip_height, total_chainwork, reorg:bool,
   reorg_depth }` event.

### 4.2 `verify_tx_inclusion` (ports `verify_transaction.rs:33-228`, minus PDA create)

1. `assert!(has_header(lc, block_hash), E_UNKNOWN_BLOCK)`. Read record → `merkle_root,
   height`. (`:100-116`)
2. **Canonical check (Sui-specific, stronger than Solana):** assert
   `canonical_hash_at(lc, height) == block_hash`. Solana only checked confirmations by
   height vs tip; because we re-point height index on reorg, this guarantees the block
   is on the *current* canonical chain, not an orphaned fork at the same height.
3. **Confirmations:** `conf = height > tip ? 0 : tip - height + 1; assert!(conf >=
   REQUIRED_CONFIRMATIONS, E_INSUFFICIENT_CONF)`. (`:118-131`)
4. **Merkle inclusion** (ports `:149-169`): `current = txid`; for i in 0..len(siblings):
   `is_left = (path_bits >> i) & 1 == 1`; `current = is_left ?
   double_sha256_pair(sibling_i, current) : double_sha256_pair(current, sibling_i)`.
   Assert `current == merkle_root`. Bound `len(siblings) <= 20`.
   - NOTE the Solana semantics: bit set ⇒ sibling is on the **left** (`is_right` in
     Solana = sibling left, current right: `double_sha256_pair(&sibling, &current)`,
     `verify_transaction.rs:159-164`). Keep identical: `path_bits` bit i set ⇒ sibling
     left. Document clearly in exporter (§8) to avoid an LR flip bug.
5. **Coinbase guard:** assert `tx_index != 0` is NOT required (deposits are never the
   coinbase, but inclusion of any tx is fine). However: assert `len(siblings) >= 1`
   UNLESS the block has a single tx (merkle_root == txid). Handle the single-tx block
   case: if `siblings` empty, require `txid == merkle_root`.
6. Return `VerifiedInclusion { txid, block_hash, block_height: height, merkle_root,
   tx_index }`. No object is created/stored (divergence from Solana's persisted
   `VerifiedTransaction`; idempotency/dedup is the deposit module's job via its
   `claimed_outpoints` set — see `btc_deposit.move:76-86`).

---

## 5. Crypto Primitives & Exact Parameters

### 5.1 Hashing
- **Block hash / txid / merkle:** `double_sha256(x) = sha2_256(sha2_256(x))` using
  `sui::hash::sha2_256`. Internal byte order throughout (NOT the reversed display
  txid). Matches `sha256.rs:27-30` and `bitcoin.rs:23-26`.
- `double_sha256_pair(l, r) = double_sha256(l || r)` over 64 bytes. Matches
  `sha256.rs:33-38`.

### 5.2 Target / bits (`pow.rs:17-34`, `difficulty.rs:43-75`)
- `target_from_bits(bits)`: `exp = (bits>>24)&0xff`, `mantissa = bits & 0x007fffff`.
  If `exp <= 3`: `value = mantissa >> (8*(3-exp))`, target = value. Else: `target =
  mantissa << (8*(exp-3))`, with the bytes laid out so target compares as a 256-bit
  big number. In `u256` this is simply `(mantissa as u256) << (8*(exp-3))` for exp>3
  and `(mantissa >> (8*(3-exp)))` for exp<=3. Guard `8*(exp-3) < 256` (exp<=34) and
  the `byte_offset+3<=32` bound from `pow.rs:28` (silently yields 0 target above —
  preserve: oversized exponent ⇒ target 0 ⇒ no hash passes).
- `MAX_TARGET_BITS = 0x1d00ffff` (mainnet). `MAX_TARGET = target_from_bits(0x1d00ffff)`.
- `hash_meets_target`: Bitcoin targets and `block_hash` are little-endian 256-bit. Two
  equivalent implementations: (a) byte-wise LE compare per `pow.rs:4-14`, or (b) convert
  `block_hash` (LE) to `u256` and compare `<= target`. Use (b) with native `u256` for
  clarity: `le_bytes_to_u256(block_hash) <= target`. MUST produce identical results —
  add a unit test cross-checking against known headers.

### 5.3 Chainwork (`pow.rs:36-70`)
- `work = 2^256 / (target + 1)`. With native `u256`, replicate the overflow-avoiding
  trick: `let tp1 = target + 1; if tp1 == 0 return 0; work = (NOT(target) / tp1) + 1`
  where `NOT(target) = (2^256 - 1) - target = u256::MAX - target` (Move has no `!` on
  u256; use `0u256 - 1` wrap? NO — Move aborts on under/overflow). Compute
  `MAX_U256 = 0xffff...ff` constant and `not_target = MAX_U256 - target`. Then
  `work = not_target / tp1 + 1`. Division and add are native u256; `/` truncates,
  matching `u256_div`. Add unit test: `work_from_bits(0x1d00ffff)` == known genesis
  work `0x0000000100010001` (=4295032833).
- Cumulative add: native `u256` `+`. (Replaces `add_chainwork`.) Overflow is
  practically impossible (chainwork of all Bitcoin history ≪ 2^256), but a malicious
  fork could try to inflate — see R5.

### 5.4 Retarget (`difficulty.rs:10-40`)
- `TARGET_TIMESPAN = 1_209_600` (2 weeks). `BLOCKS_PER_EPOCH = 2016`.
- Clamp: `clamped = clamp(actual, TARGET_TIMESPAN/4, TARGET_TIMESPAN*4)`.
- `new_target = old_target * clamped / TARGET_TIMESPAN` (native u256 mul then div;
  `clamped`, `TARGET_TIMESPAN` fit in u32). Cap at `MAX_TARGET`. Re-encode via
  `bits_from_target` (port `difficulty.rs:43-75` exactly, including the `0x00800000`
  sign-bit shift and `size+=1`).

### 5.5 Poseidon Merkle parameters — for the DEPENDENT `merkle`/`btc-deposit` modules

This module does NOT build the Poseidon commitment tree, but the spec set requires the
parameters be pinned HERE because the SPV result feeds the commitment insert. The
current `merkle.move` SHA256-chain stub (`sha2_256(prev_root || commitment)`) is WRONG
and is replaced by the `merkle` module (separate spec). The Poseidon tree MUST match
`circuits/circom/lib/merkle.circom`:

- **Hash:** `Poseidon(2)` over BN254 → Sui `sui::poseidon::poseidon_bn254(&vector[left,
  right]): u256`. (`merkle.circom:28`, `joinsplit.circom` Merkle usage.)
- **Arity:** binary (2). **Depth (`levels`):** **16** (`merkle.circom:10`,
  `sdk/src/merkle.ts:17 TREE_DEPTH = 16`, CLAUDE.md "Tree Depth 16"). 65,536 leaves.
- **Node hashing order:** `path_indices[i] == 0` ⇒ `node = Poseidon(current, sibling)`
  (current LEFT); `==1` ⇒ `Poseidon(sibling, current)` (current RIGHT).
  (`merkle.circom:31-42`.) This is the OPPOSITE bit convention from the Bitcoin merkle
  in §4.2 step 4 — do not conflate them.
- **Leaf hashing:** the leaf is the commitment itself = `Poseidon(npk, token, amount)`
  via `Poseidon(3)` (`joinsplit_commitment.circom:18-25`). No extra leaf hash.
- **Zero subtree value (empty leaf):** `ZERO_VALUE =
  0x2fe54c60d3ada40e0000000000000000000000000000000000000000`
  (`sdk/src/merkle.ts:22-24`). Zero subtree at level k = repeated
  `Poseidon(z_{k-1}, z_{k-1})` from this base. The Move tree MUST precompute the 16
  zero-subtree roots identically.
- **Field canonicalization:** every input to `poseidon_bn254` MUST be a canonical
  BN254 field element `< r` where
  `r = 21888242871839275222246405745257093699960950392725427726161990659925081120907...`
  (the BN254 scalar field). Commitments/npk/token/amount come from the circuit already
  reduced; for the Move tree, convert 32-byte big-endian field bytes → `u256` and
  `assert!(v < BN254_R)`. (See R8.)

`REQUIRED_CONFIRMATIONS = 6` (`constants.rs`), with a `regtest`/`devnet` override of 1
(`complete_deposit.rs:56-60`). Make it a per-network constant set at `initialize`.

---

## 6. Gas / Performance & Storage Growth

| Concern | Mitigation |
|---|---|
| **Unbounded header dynamic fields** (one per block forever) | Add a **prune watermark**: keep headers from `finalized_height - PRUNE_RETENTION` (e.g. 1008 blocks ≈ 1 week) up to tip. Below the watermark, headers cannot be reorged (deeper than any feasible reorg) so they're safe to drop. Pruning is a permissionless `prune_below(lc, height, hashes: vector)` that deletes dynamic fields and is rate-limited. Keep a rolling `oldest_retained_height`. Height index entries below watermark can also be dropped EXCEPT those still needed for pending-deposit confirmation windows — keep a generous margin. |
| **Side-fork headers never pruned** | Track per-stored-hash whether it's below the finalized watermark; prune orphan forks aggressively. |
| **Batch size** | `MAX_BATCH_SIZE = 10` (`constants.rs`). Each header = 1 double-SHA256 (2 sha2_256 natives) + 1 `work_from_bits` (one u256 div). Cheap. Keep cap to bound PTB gas. |
| **`verify_tx_inclusion` merkle path** | ≤ 20 double-SHA256 pairs (`verify_transaction.rs:91`). Bound `len(siblings) <= 20`. |
| **`vector<u8>` hash keys vs `u256` keys** | Prefer `u256` keys for dynamic fields (cheaper hashing/compare than 32-byte vectors). Store block hashes as `u256` (LE→u256) internally; expose `vector<u8>` at the API boundary for the deposit module. Pick ONE and be consistent (recommend `u256` internal, convert at edges). |
| **Shared-object contention** | `submit_headers` mutates the shared `LightClient`, serializing header submissions. Acceptable: one relayer submits. `verify_tx_inclusion`/`confirmations` take `&LightClient` (read-only, no contention) — deposits don't serialize against each other. |
| **Genesis checkpoint** | Do NOT start from block 0 (900k+ headers). `initialize` anchors a recent trusted checkpoint with supplied `genesis_chainwork`. Keeps the stored chain short and bounds storage. This is the standard "trustless after checkpoint" model; the checkpoint is the one trust assumption, identical to how Solana's LC is initialized in practice. |

---

## 7. Risks, Edge Cases, Security Pitfalls

- **R1 — Stub is exploitable today.** `btc_light_client.move::new_verified_deposit`
  mints with no proof (`:16-40`). Until this module ships, ANYONE mints arbitrary BTC
  deposits. Highest-priority hole; delete `new_verified_deposit` and route deposits
  through `verify_tx_inclusion` → `btc_deposit`.
- **R2 — Merkle malleability / 64-byte tx & path-length attacks.** Bitcoin's merkle
  tree is vulnerable to (a) the CVE-2012-2459 duplicate-last-node issue and (b)
  64-byte "transactions" that can be confused with internal nodes. Mitigation: (a) we
  only verify *inclusion of a specific txid* against a stored, PoW-secured merkle root,
  so duplicate-node ambiguity can't forge a different valid block; (b) require the
  caller to ALSO prove (in `btc-deposit`) that the raw tx parses as a real tx and its
  double-SHA256 equals `txid` — a 64-byte internal node won't parse as a valid tx.
  Document: this module trusts the supplied `txid`/`tx_index`; the deposit module binds
  `txid` to a real parsed transaction (mirrors `complete_deposit.rs:284-288`).
- **R3 — Reorg height-index correctness.** When a heavier fork of depth d is submitted,
  steps `parent_height+1..running_height` get re-pointed. But heights between the new
  fork's base and old tip that the new fork does NOT cover (if the new fork is SHORTER
  in block count but heavier in work — possible across a retarget) would keep stale
  canonical hashes. Mitigation: after re-pointing, if `running_height < old_tip_height`,
  **invalidate** height entries `(running_height+1 ..= old_tip_height)` (delete or mark
  empty) so `canonical_hash_at` returns none and `verify_tx_inclusion`'s canonical check
  (§4.2 step 2) fails for orphaned blocks. Solana never handled this; we MUST. Add a
  test (T-INT-5).
- **R4 — Fork from an old epoch.** Solana punted (`extend_blockchain.rs:128-134`,
  carries global LC difficulty params even when forking from an old parent). We store
  `expected_bits`/`epoch_start_time` per `HeaderRecord` and seed running state from the
  PARENT (§4.1 step 3), so a deep reorg across an epoch boundary validates difficulty
  correctly. This is a deliberate hardening over the Solana reference.
- **R5 — Chainwork inflation / cheap-fork DoS.** An attacker submits a long low-difficulty
  side chain (regtest-like) to bloat storage, or a fork with bogus bits to inflate
  chainwork. PoW + `bits == expected_bits` enforcement (step 4d) prevents fake low
  targets on mainnet; the heavier-work rule means an attacker must actually outwork the
  honest chain to reorg. Storage DoS is bounded by gas (attacker pays per header) + the
  prune watermark (R-storage). On regtest PoW is skipped — gate regtest to admin-only or
  accept it's a test network.
- **R6 — u32 timestamp wrap in retarget.** `timestamp.wrapping_sub(epoch_start)` can
  underflow if a header timestamp is < epoch start (allowed within Bitcoin's
  median-time rules ±2h). Move `u32 - u32` ABORTS on underflow. Implement an explicit
  wrapping subtract: `if ts >= start { ts - start } else { (0xFFFFFFFF - start) + ts + 1 }`
  to byte-match Rust `wrapping_sub` (`extend_blockchain.rs:229`). Then the `[ts/4, ts*4]`
  clamp tames the huge value. Add a test with `ts < epoch_start`.
- **R7 — Retarget off-by-one parity.** Bitcoin Core computes the new target from the
  timespan between the FIRST and LAST block of the 2016-window and applies it to the
  NEXT block. Solana applies it AT the boundary block. To preserve cross-chain
  commitment-root and LC parity, **match Solana exactly** (apply at `height %
  2016 == 0`). Do NOT "fix" to Core's exact semantics or the two chains' expected_bits
  will diverge. Note as a known, intentional simplification. Only matters on mainnet
  across a real retarget; test against real mainnet epoch headers (T-INT-6).
- **R8 — Poseidon field canonicalization.** `poseidon_bn254` inputs MUST be `< BN254_R`.
  Non-canonical inputs (e.g. a 32-byte value ≥ r) either abort or alias to `v mod r`,
  which would let two different byte strings produce the same commitment → double-mint.
  Enforce `assert!(v < BN254_R)` on every field input in the merkle/deposit modules.
- **R9 — Endianness traps.** Bitcoin: header fields are LE; targets/hashes compared LE;
  txids displayed reversed but hashed in internal order. BN254 field bytes: SDK uses a
  specific (big-endian) byte layout for commitments — confirm against `sdk/src/
  poseidon.ts` before wiring deposit. Mixing the two is the most likely bug class.
  Centralize all conversions in named helpers (§3.2) and unit-test each.
- **R10 — Single-tx blocks & empty merkle proof.** A block whose only tx is the
  deposit has `merkle_root == txid` and an empty sibling list. Handle explicitly
  (§4.2 step 5) or inclusion verification will wrongly fail/pass.
- **R11 — Genesis trust.** The checkpoint `genesis_chainwork` is admin-supplied and
  unverifiable on-chain. A wrong value skews reorg decisions. Mitigate by publishing the
  checkpoint hash+height+work in deploy docs and gating `initialize` behind `AdminCap`
  (one-time). This is the single accepted trust root, same as Solana.

---

## 8. Dependencies on Other Modules in This Design Set

- **`merkle` (Poseidon commitment tree)** — consumes nothing from here directly but
  shares the field-canonicalization helper and the §5.5 parameters. The SPV result
  (`VerifiedInclusion`) feeds the deposit, which inserts into this tree. Separate spec.
- **`btc-deposit`** — sole consumer of `verify_tx_inclusion` / `consume_inclusion`.
  Replaces the stub `new_verified_deposit`/`complete_verified_deposit`
  (`btc_deposit.move`, `btc_light_client.move`). Parses OP_RETURN
  (`header||pool_tag||ephemeralPub||npk`, 73 bytes), extracts
  amount from the SPV-verified tx output, applies fees, computes
  `Poseidon(npk, ZKBTC_TOKEN_ID, amount)` (`crypto.rs::compute_commitment`,
  `complete_deposit.rs:401-403`), inserts into the merkle tree, dedups via
  `claimed_outpoints`. Separate spec.
- **`pool`** — `AdminCap` reuse for `initialize`/`set_paused` (`pool.move:11`,
  `:47-50`). Confirm whether to share `pool::AdminCap` or mint a dedicated
  `LightClientAdminCap` (recommend dedicated, to decouple pause authorities).
- **`events`** — add `HeadersSubmitted` and `HeaderPruned` events
  (`events.move` pattern). Indexer (`chains/sui/indexer/src/*`) subscribes for header
  sync + reorg detection.
- **`errors`** — add codes: `E_HEADER_PREV_MISMATCH`, `E_POW_NOT_MET`, `E_BAD_BITS`,
  `E_UNKNOWN_BLOCK`, `E_NOT_CANONICAL`, `E_INSUFFICIENT_CONF`, `E_BAD_MERKLE_PROOF`,
  `E_LC_PAUSED`, `E_BAD_HEADER_LEN`, `E_BATCH_TOO_LARGE` (extend `errors.move:1-32`).
- **Off-chain `tools/sui-groth16-exporter` & header-relayer** — relayer batches
  ≤10 headers into `submit_headers`; deposit flow builds `merkle_siblings` + `path_bits`
  with the §4.2-step-4 LEFT-bit convention. `chains/sui/scripts/regtest-flow.ts:210`
  must be rewired to call `verify_tx_inclusion` instead of fabricating
  `VerifiedBtcDeposit`.

---

## 9. Test Matrix

### Unit (Move `#[test]`, pure functions)
- **U1 `target_from_bits`**: `0x1d00ffff` → mainnet max target; `0x170d8d70` (recent
  epoch) → known target; exp<=3 small-target branch; oversized exp → 0.
- **U2 `bits_from_target` round-trip**: `bits_from_target(target_from_bits(b)) == b`
  for a table of real `bits` values, incl. one triggering the `0x00800000` sign-bit
  shift (`difficulty.rs:69-72`).
- **U3 `work_from_bits`**: `0x1d00ffff` → 4295032833; a mid-difficulty epoch → value
  cross-checked vs Bitcoin Core `GetBlockProof`.
- **U4 `hash_meets_target`**: real block hash < its target → true; hash == target →
  true; hash > target → false; LE vs `u256` impls agree.
- **U5 `calculate_new_bits`**: timespan exactly target (no change); < target/4 (clamp
  low, difficulty up); > target*4 (clamp high); cap at MAX_TARGET. Cross-check a real
  mainnet retarget (e.g. epoch at height 2016, 4032).
- **U6 `double_sha256` / `_pair`**: known Bitcoin block hash from its 80-byte header;
  known merkle pair.
- **U7 timestamp wrapping sub (R6)**: `ts < epoch_start` matches Rust `wrapping_sub`.
- **U8 field canonicalization**: input ≥ BN254_R aborts (when wired to merkle).

### Integration (`test_scenario`, shared LightClient)
- **I1 init + single header**: `initialize` at checkpoint, submit 1 valid child, tip
  advances, height index set, chainwork increases.
- **I2 batch of 10**: continuity enforced; mid-batch continuity break aborts whole tx.
- **I3 bad PoW**: header whose hash > target aborts `E_POW_NOT_MET` (mainnet network).
- **I4 wrong bits**: valid PoW but `bits != expected_bits` aborts `E_BAD_BITS`.
- **I5 reorg (R3)**: build chain A (height h..h+3), then submit fork B (h..h+4) with
  more chainwork → tip = B's tip, height index re-pointed, A's orphaned blocks fail
  `verify_tx_inclusion` canonical check. Also test the shorter-but-heavier fork
  invalidating stale upper heights.
- **I6 equal-work tie**: incumbent retained.
- **I7 retarget at epoch boundary (R7)**: feed real mainnet headers spanning a 2016
  boundary; assert `expected_bits` updates to the next epoch's value matching Core.
- **I8 idempotent resubmit**: submitting the same batch twice is a no-op (no double
  count beyond first store), tip unchanged on second.
- **I9 `verify_tx_inclusion` happy path**: real block + tx + merkle proof → returns
  `VerifiedInclusion`; consumed by a test harness mimicking btc_deposit.
- **I10 insufficient confirmations**: block at `tip - 4` with REQUIRED=6 aborts
  `E_INSUFFICIENT_CONF`.
- **I11 non-canonical inclusion**: tx in an orphaned fork block aborts `E_NOT_CANONICAL`.
- **I12 bad merkle proof**: wrong sibling / wrong path_bits aborts `E_BAD_MERKLE_PROOF`.
- **I13 single-tx block**: empty siblings, `txid == merkle_root` → passes (R10).
- **I14 paused**: `submit_headers` aborts when paused.
- **I15 prune**: prune below watermark deletes headers; pruned block no longer
  resolvable; tip/finalized unaffected.

### E2E (regtest)
- **E1** rewire `chains/sui/scripts/regtest-flow.ts` to: start regtest, mine blocks,
  relay real headers via `submit_headers`, build a real merkle proof, call
  `verify_tx_inclusion`, then drive `btc_deposit`. Keep the script on that direct
  SPV path and add a second proof-checked redeem fixture before claiming full
  deposit -> transfer -> redeem coverage under regtest.

---

## 10. Effort & Open Questions

**Effort:** 6–9 developer-days.
- Core arithmetic (`target/bits/work/retarget`) leveraging native `u256`: ~1.5d
  (much of the pain is gone vs Solana's 4×u64 limbs).
- Header store + dynamic fields + submit/validate/reorg: ~2.5d.
- `verify_tx_inclusion` + canonical/confirmation logic + hot-potato wiring: ~1d.
- Pruning + storage management: ~1d.
- Tests (U + I matrix, real-header vectors): ~2d.
- E2E rewire of regtest-flow: ~1d.

**Open questions:**
1. **Checkpoint policy:** which height/hash/chainwork do we anchor at deploy, and how
   often do we re-anchor (new genesis vs append)? Affects storage ceiling.
2. **Dedicated `LightClientAdminCap` vs reuse `pool::AdminCap`?** (Recommend dedicated.)
3. **Regtest PoW handling:** skip PoW entirely (current Solana behavior, `network !=
   MAINNET`) vs require but with regtest's trivial target? Skipping is simpler; confirm
   it's only ever used on test networks.
4. **Internal key type:** `u256` (recommended, cheaper) vs `vector<u8>` for block-hash
   dynamic-field keys — lock this before implementation to avoid a refactor.
5. **Prune retention window** (1008? 2016 blocks?) and whether pruning is permissionless
   or admin-gated.
6. **Do we persist `VerifiedInclusion` at all** (Solana persisted `VerifiedTransaction`
   for cross-program reads)? Recommendation: do NOT persist (hot potato), let
   `btc_deposit::claimed_outpoints` own dedup. Confirm the deposit module's dedup is
   sufficient (it is, per `btc_deposit.move:76-86`).
7. **Median-time-past / future-time header validation:** Solana doesn't enforce MTP or
   the 2-hour future-time rule. Match Solana (skip) for parity, or add as extra
   hardening? Adding requires storing the last 11 timestamps.
