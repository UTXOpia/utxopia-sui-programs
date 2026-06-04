# Module 02 — SPV TX Inclusion Proof + Bitcoin TX Parser (Move)

Status: spec (implementation-ready)
Target: trustless mainnet parity with the Solana implementation
Source of truth ported FROM:
- `contracts/programs/btc-light-client/src/instructions/verify_transaction.rs`
- `contracts/programs/utxopia/src/utils/bitcoin.rs`
- `contracts/programs/utxopia/src/instructions/complete_deposit.rs` (consumer semantics)

This module turns a raw Bitcoin transaction + a Merkle inclusion proof into a
**verified, structured deposit tuple** that the deposit module (`btc_deposit.move`)
consumes. It does NOT mint, does NOT touch the Poseidon commitment tree, and does NOT
verify headers — header validity is Module 01's job. This module *reads* a stored,
confirmed block's `merkle_root` and `height` from Module 01 and proves a tx is in it.

---

## 1. Goal & what it replaces

### Goal
Given a confirmed Bitcoin block stored on-chain by the light client (Module 01), prove
that a raw Bitcoin transaction is included in that block via a Merkle inclusion proof,
enforce `REQUIRED_CONFIRMATIONS`, then parse the raw tx and emit a verified
`(txid, vout, amount_sats, ephemeral_pub, npk)` result.

### What it replaces (cite)
- `chains/sui/contracts/sources/btc_light_client.move:16-40`
  — `new_verified_deposit(...)` currently does **ZERO** verification: it only checks
  `vector::length` of fields (`:25-29`). Anyone can fabricate a `VerifiedBtcDeposit`
  with an arbitrary `amount_sats`, `commitment`, and `verified_root` and mint funds.
  This module supplies the real SPV path that must be the *only* way to construct a
  `VerifiedBtcDeposit`.
- The off-chain trust in `chains/sui/scripts/regtest-flow.ts` (the script currently
  computes `verifiedRoot` client-side at `:88` and hands it to the contract). After this
  module lands, the root/inclusion is proven on-chain; the script only *supplies* the
  proof bytes.

The Solana equivalents this ports from:
- Inclusion proof + confirmations: `verify_transaction.rs:80-169` (parse proof, read
  header `merkle_root`/`height`, confirmation math, sibling climb, root compare).
- Tx hashing: `verify_transaction.rs:133-147` (`double_sha256(raw_tx) == txid`).
- Tx parsing / varint / outputs / OP_RETURN: `bitcoin.rs` (`ParsedTransaction::parse`
  `:374-450`, `OutputIterator` `:549-576`, `read_varint` `:627-653`,
  `get_deposit_op_return` `:326-352`, `find_deposit_output_with_vout` `:489-496`).

---

## 2. Sui-native data model

### Key difference vs Solana
Solana `verify_transaction.rs` *persists* a `VerifiedTransaction` **PDA** (account) keyed
by `["verified_tx", block_hash, txid]` for later lookup and idempotency
(`verify_transaction.rs:171-225`). On Sui there is no "look it up by seed later" model.
Two viable designs; **we choose (B)**:

- **(A) Persisted shared object** keyed by txid — requires the consumer to fetch the
  object by ID, and requires a registry to map `txid -> object id`. Adds dynamic-field
  storage and storage-rent overhead.
- **(B) Hot-potato verified result (CHOSEN).** SPV verification and deposit completion
  happen in **one PTB**. This module returns a `VerifiedTxInclusion` value that has
  **no `key`, no `store`, no `copy`, no `drop`** (a "hot potato"). It can only be
  consumed by `btc_deposit.move` in the same transaction via a `public(package)`
  destructor. This makes it impossible to forge or persist, and naturally enforces
  "verify-then-consume atomically". Idempotency / double-claim protection lives in the
  consumer's `BtcDepositRegistry` (`btc_deposit.move:14-17,48-50`), which already keys on
  `outpoint_key(txid, vout)` — this preserves Solana's dedup intent
  (`complete_deposit.rs:206-243` deposit-receipt dedup).

```move
module utxopia::spv {
    /// Hot-potato result of a verified SPV inclusion + tx parse.
    /// NO abilities: cannot be stored, copied, dropped, or transferred.
    /// Must be consumed in-PTB by btc_deposit via consume_*.
    public struct VerifiedTxInclusion {
        txid: vector<u8>,            // 32 bytes, internal byte order (raw dsha256)
        block_hash: vector<u8>,      // 32 bytes, the block this tx is in
        block_height: u64,
        confirmations: u64,
        // deposit fields extracted from the parsed tx:
        deposit_vout: u32,           // index of the credited (non-OP_RETURN) output
        amount_sats: u64,            // value of that output
        ephemeral_pub: vector<u8>,   // 32 bytes (from OP_RETURN)
        npk: vector<u8>,             // 32 bytes (from OP_RETURN)
    }
}
```

### Inputs it reads from Module 01
The light client (Module 01) must expose a **read-only accessor** that, given a
`block_hash`, returns `(merkle_root: vector<u8>, height: u64)` for a *stored* header, and
a `tip_height(): u64` (or `finalized_height`) accessor. This mirrors the Solana reads of
`BlockHeader.merkle_root`/`height` (`verify_transaction.rs:101-116`) and
`BitcoinLightClient.tip_height()` (`:120-131`).

Required Module-01 surface (dependency, see §8):
```move
// in utxopia::btc_light_client (Module 01, hardened)
public fun block_merkle_root(lc: &LightClient, block_hash: &vector<u8>): vector<u8>;
public fun block_height(lc: &LightClient, block_hash: &vector<u8>): u64;
public fun has_block(lc: &LightClient, block_hash: &vector<u8>): bool;
public fun tip_height(lc: &LightClient): u64;
```
The light client is a **shared object** on Sui (vs Solana PDA). It is passed by `&` ref.

### Constants
```move
const REQUIRED_CONFIRMATIONS: u64 = 6;   // matches btc-light-client constants.rs:28
                                         // (devnet override = 1; gate behind a build/env
                                         //  param, see complete_deposit.rs:56-60)
const TXID_LEN: u64 = 32;
const OP_RETURN: u8 = 0x6a;
const DEPOSIT_OP_RETURN_SIZE: u64 = 64;  // ephemeral(32) + npk(32), bitcoin.rs:14
const MAX_PROOF_DEPTH: u64 = 24;         // > Solana's 20 cap (verify_transaction.rs:91);
                                         // 2^24 leaves >> any real block. Bound for DoS.
const MAX_INPUTS: u64 = 8_000;           // bounds parser loops (see §6/§7)
const MAX_OUTPUTS: u64 = 8_000;
const MAX_TX_BYTES: u64 = 400_000;       // > max standard tx; bounds DoS
```

---

## 3. Function signatures

### Entry / package API
```move
/// Verify inclusion of `raw_tx` in the block `block_hash` (stored in `lc`), enforce
/// confirmations, parse the tx, and return a hot-potato VerifiedTxInclusion.
///
/// proof layout (mirrors verify_transaction.rs:84-98) is passed as decoded args, not a
/// blob, so Move does not have to do pointer arithmetic on a packed buffer:
///   - txid:        expected txid (32 bytes, internal order) — must equal dsha256(raw_tx)
///   - block_hash:  32 bytes, block the tx claims membership in
///   - siblings:    vector<vector<u8>>, each 32 bytes, leaf->root order
///   - path_bits:   u32 bitmask; bit i == 1 => current node is the RIGHT child at level i
///   - pool_script: optional expected scriptPubKey of the credited output (Option)
public(package) fun verify_inclusion_and_parse(
    lc: &utxopia::btc_light_client::LightClient,
    raw_tx: vector<u8>,
    txid: vector<u8>,
    block_hash: vector<u8>,
    siblings: vector<vector<u8>>,
    path_bits: u32,
    pool_script: std::option::Option<vector<u8>>,
): VerifiedTxInclusion;

/// Consume the hot potato (called by btc_deposit.move). Returns the verified tuple.
public(package) fun consume(v: VerifiedTxInclusion)
    : (vector<u8> /*txid*/, u32 /*vout*/, u64 /*amount_sats*/,
       vector<u8> /*ephemeral_pub*/, vector<u8> /*npk*/, u64 /*block_height*/);

// read-only accessors (for the consumer / tests, no consumption)
public(package) fun txid(v: &VerifiedTxInclusion): vector<u8>;
public(package) fun amount_sats(v: &VerifiedTxInclusion): u64;
public(package) fun deposit_vout(v: &VerifiedTxInclusion): u32;
public(package) fun npk(v: &VerifiedTxInclusion): vector<u8>;
public(package) fun ephemeral_pub(v: &VerifiedTxInclusion): vector<u8>;
```

### Internal helpers
```move
fun double_sha256(data: &vector<u8>): vector<u8>;                  // sha2_256 twice
fun double_sha256_pair(left: &vector<u8>, right: &vector<u8>): vector<u8>;
fun compute_merkle_root(txid: vector<u8>, siblings: &vector<vector<u8>>, path_bits: u32)
    : vector<u8>;

// varint reader: returns (value, new_offset). Aborts on truncation.
fun read_varint(buf: &vector<u8>, off: u64): (u64, u64);
fun read_u32_le(buf: &vector<u8>, off: u64): u32;
fun read_u64_le(buf: &vector<u8>, off: u64): u64;

// Parser: returns the credited output (vout, value) + the OP_RETURN deposit data.
// Mirrors ParsedTransaction::parse + find_deposit_output_with_vout + find_deposit_op_return.
struct ParsedTx has drop {
    deposit_vout: u32,
    amount_sats: u64,
    ephemeral_pub: vector<u8>,
    npk: vector<u8>,
}
fun parse_tx(raw_tx: &vector<u8>, pool_script: &Option<vector<u8>>): ParsedTx;

// scans one scriptPubKey for the 64-byte deposit OP_RETURN; returns Option<(eph, npk)>.
fun parse_deposit_op_return(script: &vector<u8>): Option<(vector<u8>, vector<u8>)>;
fun slice(buf: &vector<u8>, start: u64, len: u64): vector<u8>;
```

---

## 4. Algorithm (step by step, with Solana citations)

`verify_inclusion_and_parse`:

1. **Length / bound guards** (port of `verify_transaction.rs:38-43,91-98`):
   - `vector::length(&txid) == 32`, `vector::length(&block_hash) == 32`.
   - `vector::length(&raw_tx) >= 10` and `<= MAX_TX_BYTES`.
   - `vector::length(&siblings) <= MAX_PROOF_DEPTH`; every sibling is exactly 32 bytes.
   - abort `E_INVALID_SPV_PROOF` otherwise.

2. **Tx hash binding** (port of `verify_transaction.rs:133-147`,
   `complete_deposit.rs:284-288`):
   - `computed = double_sha256(&raw_tx)`.
   - assert `computed == txid` (both internal byte order). This is the **only** binding
     between the proof leaf and the raw bytes; without it a parser could be fed unrelated
     bytes. abort `E_TXID_MISMATCH`.

3. **Block lookup** (port of `verify_transaction.rs:71-116`):
   - assert `btc_light_client::has_block(lc, &block_hash)` else `E_BLOCK_NOT_FOUND`.
   - `root = btc_light_client::block_merkle_root(lc, &block_hash)`.
   - `height = btc_light_client::block_height(lc, &block_hash)`.

4. **Confirmations** (port of `verify_transaction.rs:118-131`,
   `complete_deposit.rs:262-274`):
   - `tip = btc_light_client::tip_height(lc)`.
   - `confirmations = if (height > tip) 0 else tip - height + 1`.
   - assert `confirmations >= REQUIRED_CONFIRMATIONS` else `E_INSUFFICIENT_CONFIRMATIONS`.

5. **Merkle inclusion climb** (port of `verify_transaction.rs:149-169`):
   - `current = txid` (leaf == txid, internal order — Bitcoin merkle uses internal-order
     hashes, never the display-reversed txid).
   - for `i in 0..len(siblings)`:
     - `sibling = siblings[i]`.
     - `is_right = (path_bits >> i) & 1 == 1`.
     - `current = if is_right { double_sha256_pair(&sibling, &current) }`
       `else { double_sha256_pair(&current, &sibling) }`
       (Solana: right sibling means *we* are the right node, so sibling goes left —
       matches `verify_transaction.rs:159-164`).
   - assert `current == root` else `E_MERKLE_ROOT_MISMATCH`.

6. **Parse tx** (port of `ParsedTransaction::parse` `bitcoin.rs:374-450`): call
   `parse_tx(&raw_tx, &pool_script)` (see §4b). Get `(deposit_vout, amount_sats,
   ephemeral_pub, npk)`.

7. **Construct hot potato** with all fields; return it. No object created, no event
   emitted here (events belong to the consumer `btc_deposit.move`, matching Solana where
   `complete_deposit.rs:421-452` emits).

`consume`: destructure and return the tuple; the struct has no `drop`, so the only legal
exit is destructuring (Move enforces this at compile time — this is the forgery defense).

### 4b. `parse_tx` algorithm (port of `bitcoin.rs:374-518`)

Operate on `off: u64` cursor over `raw_tx`. Every read first checks bounds and aborts
`E_TX_TRUNCATED` if `off + need > len` (Solana relies on slice panics / explicit
`offset > raw_tx.len()` checks at `:405,413,430,437`; Move must do explicit checks
because there is no slice-panic-to-Result).

1. `off = 0`. `len = vector::length(raw_tx)`.
2. **version**: skip 4 bytes (`bitcoin.rs:381-383`). `off += 4`.
3. **segwit marker** (`bitcoin.rs:385-392`): if `len > off+2 && raw_tx[off]==0x00 &&
   raw_tx[off+1]==0x01` then `off += 2` (skip marker+flag). Note we ignore the witness
   section entirely — outputs are before witnesses, and `txid` (step 2) is computed over
   the **full serialized bytes including witness** here, matching Solana
   (`complete_deposit.rs:285` hashes the raw buffer as-is). See §7 "malleability".
4. **input count**: `(in_count, off) = read_varint(raw_tx, off)`; assert
   `in_count <= MAX_INPUTS`.
5. **skip inputs** (`bitcoin.rs:402-416`): repeat `in_count` times:
   - `off += 36` (prev outpoint: 32 txid + 4 vout); bound check.
   - `(script_len, off) = read_varint(...)`; `off += script_len + 4` (script + sequence);
     bound check.
6. **output count**: `(out_count, off) = read_varint(...)`; assert
   `out_count <= MAX_OUTPUTS`.
7. **iterate outputs** (port of `OutputIterator::next` `bitcoin.rs:552-575` +
   `find_deposit_output_with_vout` `:489-496` + `find_deposit_op_return` `:509-518` +
   optional `find_output_by_script` `:499-506`):
   - track `found_deposit: bool`, `deposit_vout`, `amount_sats`.
   - track `found_op_return: bool`, `ephemeral_pub`, `npk`.
   - for `i in 0..out_count`:
     - `value = read_u64_le(raw_tx, off)`; `off += 8`; bound check.
     - `(script_len, off) = read_varint(...)`; `script_end = off + script_len`; bound
       check; `script = slice(raw_tx, off, script_len)`; `off = script_end`.
     - **OP_RETURN branch**: if `script_len >= 1 && script[0] == OP_RETURN`:
       - `parse_deposit_op_return(&script)` — if `Some((eph,npk))` and not yet found,
         record it. (Do NOT treat OP_RETURN as a deposit output.)
     - **credited-output branch** (port `find_deposit_output_with_vout` /
       `find_output_by_script`): else if `!found_deposit`:
       - if `pool_script` is `Some(s)`: select this output only if `script == s` and
         `value > 0` (port `bitcoin.rs:499-506` + `complete_deposit.rs:350-366`,
         enforces output is pool/Ika-controlled).
       - else: select the **first** non-OP_RETURN output with `value > 0`
         (`bitcoin.rs:489-496`).
       - on select: `found_deposit = true; deposit_vout = i; amount_sats = value`.
8. **Post-loop asserts**:
   - assert `found_deposit` else `E_NO_DEPOSIT_OUTPUT`.
   - assert `found_op_return` else `E_NO_DEPOSIT_OP_RETURN`.
   - (locktime / witness trailing bytes are not parsed; we stop after outputs — Solana
     also stops at `offset` after outputs, `bitcoin.rs:442-449`.)

### 4c. `parse_deposit_op_return` (exact port of `bitcoin.rs:326-352`)
Accept exactly two encodings, both yielding 64 payload bytes:
- **Direct push**: `len(script) == 66 && script[0]==0x6a && script[1]==0x40` → payload =
  `script[2..66]`.
- **PUSHDATA1**: `len(script) == 67 && script[0]==0x6a && script[1]==0x4c &&
  script[2]==0x40` → payload = `script[3..67]`.
- anything else → `None` (e.g. the 32-byte commitment OP_RETURN at `:309-322` must NOT
  match — see test `test_deposit_op_return_wrong_size` `bitcoin.rs:714-725`).
- `ephemeral_pub = payload[0..32]`, `npk = payload[32..64]`.

---

## 5. Crypto primitives & exact parameters

| Primitive | Spec | Notes |
|-----------|------|-------|
| Tx hash | `sha2_256(sha2_256(raw_tx))` | Bitcoin double-SHA256. Use `std::hash::sha2_256` twice. Result is **internal byte order** (NOT reversed). `bitcoin.rs:24-27`. |
| Merkle node | `double_sha256(left ‖ right)` over 64 bytes | `bitcoin.rs:96-101`. Concatenate then double-hash. |
| Merkle leaf | the txid itself (internal order) | Bitcoin merkle leaves are the txids; no extra hashing of the leaf. |

This module uses **SHA256 only** (Bitcoin domain). It does **NOT** use
`sui::poseidon::poseidon_bn254`. Poseidon is exclusively the commitment-tree module's
concern (Module 03 / `merkle.move`). Therefore there is **no BN254 field-element
canonicalization risk in this module** — all values are raw 32-byte SHA256 digests and
little-endian integers. (The npk/ephemeral_pub bytes are passed downstream verbatim; it is
the deposit/commitment module that must canonicalize npk as a BN254 field element before
`poseidon_bn254`, per `complete_deposit.rs:403`.)

Note `std::hash` exposes `sha2_256(data: vector<u8>): vector<u8>` — confirmed already used
in `merkle.move:27`. There is no native double-sha256, so we compose two calls; cost is
2 sha256 invocations per node.

---

## 6. Gas / performance

- **Sibling climb**: ≤ `MAX_PROOF_DEPTH` (24) iterations, each = 2 SHA256 over 64 bytes.
  Cheap and bounded.
- **`vector::borrow` indexing**: Move vectors are O(1) index; the `bitcoin.rs` zero-copy
  slice trick does not translate — we copy with `slice()` only for the credited script and
  the OP_RETURN script (small). **Do not** `slice` the whole inputs/outputs region; walk
  with a `u64` cursor over the original `raw_tx` to avoid O(n) copies.
- **Input skipping**: O(in_count); each input only advances the cursor by varint +
  fixed sizes — no copies. Bound by `MAX_INPUTS`.
- **Output iteration**: O(out_count); copies only the per-output script (≤ a few hundred
  bytes). Bound by `MAX_OUTPUTS`.
- **`raw_tx` is passed by value** (`vector<u8>`). For a large tx (up to `MAX_TX_BYTES`)
  this is one move into the call; acceptable. Pass by `&vector<u8>` to all internal
  helpers to avoid clones (sketched in §3).
- **Avoid per-byte `vector::push_back` for u32/u64 reads**; read bytes directly and
  shift-accumulate (`read_u32_le`/`read_u64_le`) to minimize allocations.
- **PTB-atomic design** (hot potato) means no object storage rent for the verified result
  — strictly cheaper than the Solana PDA-persist model.

---

## 7. Risks, edge cases, security pitfalls

1. **Stub forgery (the bug we fix).** Today `new_verified_deposit` mints on length
   checks alone (`btc_light_client.move:16-40`). The hot-potato `VerifiedTxInclusion` with
   no `drop`/`store`/`copy` means it can **only** originate from
   `verify_inclusion_and_parse` and **must** be consumed in-PTB — there is no constructor
   for `btc_deposit` to call directly. Module 01's `new_verified_deposit` must be
   **deleted/privatized**; `btc_deposit::complete_verified_deposit`
   (`btc_deposit.move:27-70`) must be rewritten to take a `VerifiedTxInclusion` instead of
   a `VerifiedBtcDeposit`.

2. **Tx malleability (segwit).** The `txid` MUST be computed over the **legacy
   (non-witness) serialization** for true malleability resistance. Two sub-risks:
   - If the relayer supplies the *full* witness-serialized bytes and we `dsha256` them,
     the result is the **wtxid**, which is NOT in the block's tx-merkle tree (that tree is
     built from legacy txids). The inclusion proof would then fail (root mismatch) — a
     liveness bug, not a safety bug. **Decision:** require the relayer to submit the
     **legacy-serialized** tx bytes (strip marker+flag+witness). The parser still tolerates
     a segwit marker (step 4.3) for robustness, but the canonical hashing input for
     deposits should be legacy bytes. Document this requirement for the indexer/relayer
     (Module 06 / scripts). Add an integration test feeding both forms.
   - Pre-segwit (legacy) malleability of signatures is irrelevant here because we key the
     deposit dedup on `outpoint(txid,vout)` in the registry, and the amount/OP_RETURN come
     from the (now confirmed) included tx; a malleated alternative would have a different
     txid and would not be in the proven block.

3. **Parser DoS / bounds.** Move aborts on out-of-bounds `vector::borrow`, but an abort
   still costs gas and could be used to grief a sponsor. Mitigate with explicit pre-read
   bound checks returning a clean `E_TX_TRUNCATED`, and hard caps `MAX_TX_BYTES`,
   `MAX_INPUTS`, `MAX_OUTPUTS`, `MAX_PROOF_DEPTH`. Reject `script_len`/varint values that
   would overflow the cursor (`off + script_len > len`) **before** advancing.

4. **Varint canonicality.** Bitcoin consensus does not require minimal varint encoding,
   but a malicious relayer can only hurt themselves: a non-canonical varint that still
   parses yields some `txid`-bound tx; if it does not match the block, inclusion fails.
   We do **not** enforce minimality (matches Solana `read_varint` `bitcoin.rs:627-653`).
   We DO bound `0xff` varints implicitly via `MAX_INPUTS/OUTPUTS` and the `off` checks.

5. **Integer overflow.** `off + need`, `off + script_len`: use `u64` and check
   `need <= len - off` form (compute the complement to avoid `off+need` wrap) or rely on
   Move's checked arithmetic (Move aborts on `u64` overflow by default — acceptable, but
   prefer the explicit complement form for a clean error code). `amount_sats` is `u64`
   straight from 8 LE bytes; no sum across outputs is needed for the credited value (unlike
   `sum_outputs` `bitcoin.rs:462-468`), so no saturating-add concern in this module.

6. **path_bits length vs siblings length.** `path_bits` is u32 ⇒ supports ≤ 32 levels;
   `MAX_PROOF_DEPTH = 24` keeps us within range. Only the low `len(siblings)` bits are
   consulted; higher bits are ignored (matches Solana looping `0..path_len`,
   `verify_transaction.rs:155`). No `tx_index` is needed because `path_bits` already
   encodes left/right at each level.

7. **Self-pairing / duplicate-tx merkle attack (CVE-2012-2459).** Bitcoin merkle trees
   duplicate the last node on odd rows; a crafted tree can make two different blocks share
   a merkle root. This is a **header-validity** concern (PoW + the 64-byte interior-node
   ambiguity). Module 01 must reject blocks whose coinbase/merkle is malformed. This module
   trusts Module 01's stored `merkle_root`; it does not re-derive the tree, so it inherits
   Module 01's guarantees. **Note this dependency explicitly** (§8). The relayer must not
   supply an inclusion proof of length where a 64-byte "tx" could be confused with an
   interior node — but since we bind `txid == dsha256(raw_tx)` and `raw_tx >= 10` bytes
   and is a real parseable tx, a 64-byte interior node cannot masquerade as our leaf.

8. **OP_RETURN ambiguity.** A tx could contain multiple OP_RETURN outputs. We take the
   **first** that matches the 64-byte deposit layout (`find_deposit_op_return` semantics,
   `bitcoin.rs:509-518`). The 32-byte commitment OP_RETURN (`:309-322`) is explicitly NOT
   matched. Document that the deposit OP_RETURN must be the canonical one.

9. **vout vs OP_RETURN index.** `deposit_vout` is the **absolute** output index `i` in
   the tx (OP_RETURN outputs are counted in the index), matching
   `find_deposit_output_with_vout` enumerate (`bitcoin.rs:490`). The registry dedup keys on
   `(txid, deposit_vout)` (`btc_deposit.move:88-95`) — must use this absolute index.

10. **Replay across blocks (reorg).** Because the result is hot-potato and the registry
    dedups on outpoint, a tx mined in a reorged-away block cannot be double-claimed: the
    first claim records the outpoint; a re-proof against a different `block_hash` for the
    same outpoint is rejected by the registry. Module 01 must only retain headers on the
    most-work chain; a tx proven against an orphaned header would still need ≥6
    confirmations on a chain Module 01 considers canonical. This module enforces
    confirmations against `tip_height`; it relies on Module 01 chainwork-reorg correctness.

---

## 8. Dependencies on other modules in this design set

- **Module 01 — btc-light-client (header chain + PoW + retarget + chainwork reorg).**
  HARD dependency. This module needs new read accessors `block_merkle_root`,
  `block_height`, `has_block`, `tip_height` on the shared `LightClient` object (§2). It
  also relies on Module 01 to reject malformed/low-work headers and CVE-2012-2459-style
  merkle malleability (risk §7.7). The current `btc_light_client.move` (the stub) is
  replaced by Module 01 + this module jointly: `new_verified_deposit`/
  `consume_verified_deposit`/`VerifiedBtcDeposit` (`btc_light_client.move:6-56`) are
  removed and superseded by `VerifiedTxInclusion`.
- **Module 03 — Poseidon commitment tree / `btc_deposit.move` consumer.** Consumes the
  `VerifiedTxInclusion` hot potato via `consume`, computes
  `Poseidon(npk, ZKBTC_TOKEN_ID, amount - fee)` (`complete_deposit.rs:401-403`), inserts
  the leaf, and emits events. `btc_deposit::complete_verified_deposit`
  (`btc_deposit.move:27-70`) is rewritten to take `VerifiedTxInclusion` and `lc`.
- **errors.move** — add new codes (see below); reuse `E_INVALID_BTC_DEPOSIT`,
  `E_BTC_DEPOSIT_ALREADY_CLAIMED` (`errors.move:14-15`).
- **events.move** — no change needed in this module (consumer emits
  `btc_deposit_verified` `events.move:90-110`).
- **Indexer / scripts** (`chains/sui/scripts/regtest-flow.ts`, indexer `bitcoin-node.ts`):
  must build the inclusion proof (siblings + path_bits) and supply **legacy-serialized**
  raw tx bytes. Off-chain root computation at `regtest-flow.ts:88` is removed.

New error codes to add to `errors.move`:
```
E_INVALID_SPV_PROOF, E_TXID_MISMATCH, E_BLOCK_NOT_FOUND,
E_INSUFFICIENT_CONFIRMATIONS, E_MERKLE_ROOT_MISMATCH,
E_TX_TRUNCATED, E_NO_DEPOSIT_OUTPUT, E_NO_DEPOSIT_OP_RETURN
```

---

## 9. Test matrix

### Unit — hashing & merkle
- `test_double_sha256_known_vector` — known Bitcoin tx → known txid.
- `test_merkle_single_leaf` — empty siblings, `current == root == txid`.
- `test_merkle_left_child` — path_bits bit0=0, sibling on right.
- `test_merkle_right_child` — path_bits bit0=1, sibling on left
  (port of `verify_transaction.rs:159-164` orientation).
- `test_merkle_depth_n` — real regtest block, full path to root.
- `test_merkle_root_mismatch_aborts` — corrupted sibling ⇒ `E_MERKLE_ROOT_MISMATCH`.
- `test_proof_too_deep_aborts` — `siblings.len() > MAX_PROOF_DEPTH`.
- `test_sibling_wrong_length_aborts` — a 31-byte sibling.

### Unit — varint (port `bitcoin.rs:659-664`)
- `0x00→0`, `0xfc→252`, `0xfd 0x00 0x01→256`, `0xfe ...→u32`, `0xff ...→u64`.
- truncated varint (`0xfd` with 1 byte left) ⇒ `E_TX_TRUNCATED`.

### Unit — OP_RETURN (port `bitcoin.rs:680-725`)
- `direct_push` (0x6a 0x40 + 64) → `(eph,npk)`.
- `pushdata1` (0x6a 0x4c 0x40 + 64) → `(eph,npk)`.
- `wrong_size` (0x6a 0x20 + 32) → `None`, and tx-level ⇒ `E_NO_DEPOSIT_OP_RETURN`.
- trailing garbage after 64 payload (len 67 direct) → `None`.

### Unit — output selection (port `bitcoin.rs:826-935`)
- `single_output` → vout 0.
- `op_return_first` → credited vout 1 (OP_RETURN at 0 skipped, but index counted).
- `multiple_outputs` → first non-OP_RETURN, vout 0.
- `zero_value_skipped` → vout 1.
- `all_op_return` → `E_NO_DEPOSIT_OUTPUT`.
- `pool_script_match` → selects the output whose script == pool_script (port
  `find_output_by_script` + `complete_deposit.rs:350-366`).
- `pool_script_no_match` → `E_NO_DEPOSIT_OUTPUT`.

### Unit — tx parse robustness
- `truncated_after_version` ⇒ `E_TX_TRUNCATED`.
- `truncated_in_inputs` / `truncated_in_outputs` ⇒ `E_TX_TRUNCATED`.
- `over_max_inputs` ⇒ abort.
- `over_max_tx_bytes` ⇒ abort.
- `segwit_marker_tolerated` — segwit-serialized tx still parses outputs (but see
  malleability note: hashing legacy form).

### Integration (regtest, end-to-end PTB)
- **happy path**: mine real regtest deposit tx with `0x6a 0x40 ‖ eph ‖ npk`, 6 confs,
  build proof from regtest, `verify_inclusion_and_parse` → `consume` →
  `btc_deposit::complete_verified_deposit` mints; assert event
  `BtcDepositVerified` (`events.move:90`) has correct amount/vout/npk.
- **insufficient confirmations**: tx in tip block (1 conf) ⇒ `E_INSUFFICIENT_CONFIRMATIONS`.
- **block not in light client** ⇒ `E_BLOCK_NOT_FOUND`.
- **txid/raw mismatch**: pass mismatched txid ⇒ `E_TXID_MISMATCH`.
- **wrong-block proof**: valid tx, sibling path for a different block ⇒
  `E_MERKLE_ROOT_MISMATCH`.
- **double claim**: same `(txid,vout)` twice ⇒ `E_BTC_DEPOSIT_ALREADY_CLAIMED`
  (registry, `btc_deposit.move:49`).
- **hot-potato cannot persist**: compile-fail test (negative) — attempt to
  `transfer`/store a `VerifiedTxInclusion` must not compile (documented, asserted by code
  review since Move has no runtime "this should not compile" test).
- **legacy-vs-witness serialization**: feed witness-serialized bytes; assert
  `E_MERKLE_ROOT_MISMATCH` (wtxid not in tree) unless relayer strips witness; feed legacy
  form → success.

---

## 10. Effort estimate & open questions

### Effort: 4–6 developer-days
- Day 1: `double_sha256`, `double_sha256_pair`, `compute_merkle_root`, `read_varint`,
  LE readers + unit tests.
- Day 2: `parse_tx` + `parse_deposit_op_return` + output-selection + unit tests
  (port the full `bitcoin.rs` test suite).
- Day 3: `VerifiedTxInclusion` hot-potato + `verify_inclusion_and_parse` glue; wire
  Module-01 accessor stubs; rewrite `btc_deposit::complete_verified_deposit` consumer.
- Day 4: regtest integration (proof builder in TS, legacy-serialization handling),
  remove `regtest-flow.ts:88` off-chain root.
- Day 5–6 (buffer): malleability tests, DoS bounds, code review of the no-abilities
  forgery defense, indexer proof-builder.

### Open questions
1. **Legacy vs witness serialization contract** — confirm the relayer/indexer always
   submits legacy-serialized bytes (no marker/flag/witness) so `dsha256(raw_tx)` == the
   block's tx-merkle leaf. If we instead want to accept witness-serialized bytes, the
   parser must strip the witness and re-serialize before hashing (more code, more gas).
   Recommend: enforce legacy bytes off-chain; parser tolerates but does not require the
   marker.
2. **Devnet confirmation override** — Solana uses `DEMO_REQUIRED_CONFIRMATIONS = 1` on
   devnet (`complete_deposit.rs:56-60`). Decide whether to gate via a Move build flag, a
   config field on the shared `LightClient`/`Pool`, or a published-package constant. A
   config field is most flexible but adds a trust knob; recommend a compile-time const per
   network package build to keep mainnet trustless.
3. **Does Module 01 expose `tip_height` or `finalized_height`?** Solana uses
   `tip_height` for the confirmation count (`verify_transaction.rs:122`) while
   `initialize.rs:100-101` tracks a separate `finalized_height`. Confirm which Module 01
   exposes; if it exposes a finalized height that already bakes in the 6-conf buffer, this
   module should NOT also subtract — avoid double-counting. Spec assumes raw `tip_height`
   and this module does the confirmation math.
4. **pool_script source** — should `pool_script` come from on-chain `Pool`/`PoolConfig`
   (analogous to `complete_deposit.rs:350-366`) rather than a caller-supplied arg, to
   prevent a relayer from crediting an attacker output? Strongly recommend the consumer
   (`btc_deposit`) fetch `pool_script` from `Pool` and pass it in, not trust the PTB arg.
   Spec models it as an `Option` arg but the consumer must source it from on-chain state.
