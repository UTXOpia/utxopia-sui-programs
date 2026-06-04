# 03 — On-Chain Poseidon Commitment Merkle Tree (Sui / Move)

Status: spec, implementation-ready
Module set: production-hardening of `chains/sui`
Author: hardening design pass
Last updated: 2026-06-04

---

## 0. TL;DR

Replace the fake SHA256 "root chain" in `chains/sui/contracts/sources/merkle.move` with a **real
incremental binary Poseidon Merkle tree of depth 16**, using Sui's native
`sui::poseidon::poseidon_bn254(&vector<u256>): u256`. The tree must produce the **exact same root**
the circom JoinSplit circuit verifies against, so that deposit commitments and transact output
commitments are actually provable (`MerkleProofVerifier(16)` in
`circuits/circom/lib/merkle.circom`). This is the lynchpin that makes deposit → transact chain.

The algorithm is a direct port of the Solana incremental tree in
`contracts/programs/utxopia/src/state/commitment_tree.rs` (frontier cache + precomputed zero ladder +
rolling root history). The zero-hash ladder, tree depth, node hashing, and leaf representation are
all **already fixed** by the existing Solana contract and SDK and **must not be changed** — they are
the cross-chain interop contract.

---

## 1. Goal & What It Replaces

### 1.1 Current stub (what we are deleting)

`chains/sui/contracts/sources/merkle.move`:

- **Line 27**: `hash::sha2_256(preimage)` where `preimage = current_root || commitment`. This is a
  **SHA256 hash chain**, NOT a Merkle tree. `derive_next_root` (lines 21–28) folds each new
  commitment into a running 32-byte digest. The resulting `latest_root` has **no relationship** to
  the Poseidon Merkle root the circuit computes. Any `transact` proof would verify against a circuit
  root that the chain can never reproduce — deposits can never be spent.
- **`insert_commitment` (lines 9–19)**: emits a `commitment_inserted` event, bumps
  `pool.next_leaf_index`, and overwrites `pool.latest_root` via the SHA256 chain. No frontier, no
  per-level subtree caching, no historical roots.

Pool state today (`pool.move` lines 15–22) stores a single `latest_root: vector<u8>` and a scalar
`latest_root_index`. There is **no root history**, so `transact.move:24`
(`assert_public_input_at(&public_inputs, 0, &pool::latest_root(pool))`) only accepts the single
**current** root — a deposit landing between a user's proof generation and their transact submission
permanently invalidates that proof. This must be fixed here (root history).

### 1.2 Target

A `CommitmentTree` shared object that:

1. Appends commitments via an **incremental Merkle tree** (≈16 Poseidon hashes / insert).
2. Maintains a **frontier** (`filled_subtrees`) so inserts are O(depth) not O(2^depth).
3. Maintains a **rolling root history** (ring buffer, size 100) so `transact` can validate against
   recent roots, not only the latest.
4. Produces roots **bit-identical** to `circuits/circom/lib/merkle.circom`'s `MerkleProofVerifier`,
   to the Solana on-chain tree, and to the SDK's `commitment-tree.ts`.

### 1.3 Source-of-truth files (read these; do not re-derive)

| Concern | File | Lines |
|---|---|---|
| Incremental tree algorithm (PORT FROM) | `contracts/programs/utxopia/src/state/commitment_tree.rs` | 191–239 (`insert_leaf`) |
| Zero-hash ladder (depth 0..16) | `commitment_tree.rs` | 31–49 |
| Root history ring buffer | `commitment_tree.rs` | 161–184 (`is_valid_root`, `update_root`) |
| Node hash = Poseidon(left,right) arity 2 | `circuits/circom/lib/merkle.circom` | 28–42 |
| path_index semantics (0=left child) | `merkle.circom` | 31–37 |
| Commitment leaf = Poseidon(npk,token,amount) | `circuits/circom/lib/joinsplit_commitment.circom` | 14–26 |
| SDK reference impl + zero ladder | `sdk/src/commitment-tree.ts` | 30–67, 204–360 |
| Public-input root check (consumer) | `chains/sui/contracts/sources/transact.move` | 24 |
| Stub being replaced | `chains/sui/contracts/sources/merkle.move` | 21–28 |

---

## 2. Crypto Primitives & Exact Parameters (DO NOT CHANGE)

These are the interop contract. They are confirmed by reading the circom + Solana + SDK sources
above and **must** be reproduced exactly.

| Parameter | Value | Source of truth |
|---|---|---|
| Curve / field | BN254 scalar field Fr | circom `Poseidon`, Sui `poseidon_bn254` |
| Fr modulus (`r`) | `21888242871839275222246405745257275088548364400416034343698204186575808495617` (`0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001`) | `crypto.rs:11` |
| Tree depth | **16** (2^16 = 65,536 leaves) | `commitment_tree.rs:19`, `merkle.circom` levels |
| Arity | **Binary** (2 children/node) | `merkle.circom:28` `Poseidon(2)` |
| Node hash | `parent = Poseidon([left, right])` (ordered 2-element vector) | `merkle.circom:39-42` |
| Leaf value | the commitment field element `Poseidon(npk, token, amount)` itself (NOT re-hashed) | `merkle.circom:23` `hashes[0] <== leaf` |
| Empty-leaf zero | `ZERO[0] = 0` | `commitment_tree.rs:32`, `commitment-tree.ts:46` |
| Zero ladder | `ZERO[i] = Poseidon(ZERO[i-1], ZERO[i-1])` | `commitment_tree.rs:25-26` |
| Empty-tree root | `ZERO[16]` | `commitment_tree.rs:138` |
| Left/right rule | leaf at even index = **left** child; bit `i` of leaf index selects side at level `i` | `crypto.rs:296-302`, `commitment_tree.rs:215-222`, `merkle.circom` path_indices |
| Reference vectors | `Poseidon([1,2]) = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`; `Poseidon([1,2,3]) = 0x0e7732d89e6939c0ff03d5e58dab6302f3230e269dc5b968f725df34ab36d732` | `crypto.rs:588-595, 575-583` |

### 2.1 The 17 zero hashes (levels 0..16) — paste verbatim

These are the **exact** constants from `commitment_tree.rs:31-49` and `commitment-tree.ts:45-62`
(big-endian hex, each `< r`). In Move they become `u256` literals:

```
ZERO[0]  = 0x0000000000000000000000000000000000000000000000000000000000000000  // empty leaf
ZERO[1]  = 0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864
ZERO[2]  = 0x1069673dcdb12263df301a6ff584a7ec261a44cb9dc68df067a4774460b1f1e1
ZERO[3]  = 0x18f43331537ee2af2e3d758d50f72106467c6eea50371dd528d57eb2b856d238
ZERO[4]  = 0x07f9d837cb17b0d36320ffe93ba52345f1b728571a568265caac97559dbc952a
ZERO[5]  = 0x2b94cf5e8746b3f5c9631f4c5df32907a699c58c94b2ad4d7b5cec1639183f55
ZERO[6]  = 0x2dee93c5a666459646ea7d22cca9e1bcfed71e6951b953611d11dda32ea09d78
ZERO[7]  = 0x078295e5a22b84e982cf601eb639597b8b0515a88cb5ac7fa8a4aabe3c87349d
ZERO[8]  = 0x2fa5e5f18f6027a6501bec864564472a616b2e274a41211a444cbe3a99f3cc61
ZERO[9]  = 0x0e884376d0d8fd21ecb780389e941f66e45e7acce3e228ab3e2156a614fcd747
ZERO[10] = 0x1b7201da72494f1e28717ad1a52eb469f95892f957713533de6175e5da190af2
ZERO[11] = 0x1f8d8822725e36385200c0b201249819a6e6e1e4650808b5bebc6bface7d7636
ZERO[12] = 0x2c5d82f66c914bafb9701589ba8cfcfb6162b0a12acf88a8d0879a0471b5f85a
ZERO[13] = 0x14c54148a0940bb820957f5adf3fa1134ef5c4aaa113f4646458f270e0bfbfd0
ZERO[14] = 0x190d33b12f986f961e10c0ee44d8b9af11be25588cad89d416118e4bf4ebe80c
ZERO[15] = 0x22f98aa9ce704152ac17354914ad73ed1167ae6596af510aa5b3649325e06c92
ZERO[16] = 0x2a7c7c9b6ce5880b9f6f228d72bf6a575a526f29c66ecceef8b753d38bba7323  // empty-tree root
```

> **Hard requirement (test #U2 below):** the implementation MUST recompute this ladder at build/test
> time from `ZERO[0]=0` using the actual `poseidon_bn254` node hash and assert equality with these
> literals. If `poseidon_bn254`'s parameterization ever diverged from circomlib, this test fails loudly
> rather than silently producing unspendable deposits. (Sui's `poseidon_bn254` is the standard
> circom/circomlibjs BN254x5 Poseidon; this test confirms it.)

### 2.2 `poseidon_bn254` semantics & canonicalization

Native signature: `public fun sui::poseidon::poseidon_bn254(data: &vector<u256>): u256`.

- It accepts a vector of `u256`, interprets each as a **field element**, and **aborts** if any
  element is `>= r` (the BN254 scalar modulus). It returns the Poseidon hash as a `u256 < r`.
- Element ordering matters: `poseidon_bn254(&vector[left, right])` ≡ circomlib `Poseidon(2)` with
  `inputs[0]=left, inputs[1]=right`. We rely on this matching `merkle.circom:39-41`.
- **Canonicalization is the caller's job.** Every input element we feed MUST already be `< r`.
  Commitments produced by `Poseidon(npk,token,amount)` are always `< r` by construction. Frontier
  and zero-ladder values are Poseidon outputs, hence `< r`. The only externally-supplied value is the
  raw `commitment` bytes coming into `insert_commitment`; see §6.3 for the canonicalization guard.

> **Important divergence from Solana to NOT replicate:** Solana's `crypto.rs:59-68` `reduce_to_field`
> masks the top nibble (`val[0] &= 0x2F`) to force-reduce out-of-range inputs. **Do NOT port that.**
> On Sui we instead **reject** (abort) any commitment `>= r`. A valid commitment is always a Poseidon
> output and therefore `< r`; an out-of-range commitment can only come from a malformed/forged caller
> and must be rejected, not silently mangled (silent mangling would also desync from the circuit). See
> §7 risk R4.

---

## 3. Sui-Native Data Model

### 3.1 Object model vs Solana PDAs

| Solana | Sui |
|---|---|
| `CommitmentTree` PDA (`seeds=["commitment_tree"]`), zero-copy `#[repr(C)]` 3.8 KB account | A **shared object** `CommitmentTree { id: UID, ... }` |
| Discriminator byte `0x05` | Move type identity (no discriminator needed) |
| `bump` seed | n/a |
| Account owned by program; mutated in-place | Shared object; mutated by entry fns that take `&mut CommitmentTree` |
| Manual byte (de)serialization | Native Move struct fields |

**Decision:** make `CommitmentTree` its own shared object, NOT a field embedded in `Pool`.
Rationale: (a) the root history (100×32B) + frontier (16×32B) is large and changes on every
deposit/transact; keeping it separate from `Pool` keeps `Pool` small and reduces contention/object
size; (b) it mirrors the Solana separation (`Pool`/`PoolConfig` vs `CommitmentTree`); (c) `transact`
and `complete_deposit` already need `&mut Pool` — they will additionally take
`&mut CommitmentTree`. The `Pool.latest_root` / `latest_root_index` / `next_leaf_index` fields in
`pool.move` (lines 18–20) become **vestigial and must be removed** (or repurposed) — the tree object
is now the single source of truth for root + leaf count. (Touching `pool.move` is required; see §8.)

### 3.2 Structs

```move
module utxopia::commitment_tree {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;

    const TREE_DEPTH: u64 = 16;
    const MAX_LEAVES: u64 = 1 << 16;            // 65_536
    const ROOT_HISTORY_SIZE: u64 = 100;
    // BN254 Fr modulus, as u256 literal (see §2)
    const BN254_FR: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    /// Shared object. One per tree (tree_number). Mirrors Solana CommitmentTree PDA.
    public struct CommitmentTree has key {
        id: UID,
        tree_number: u32,            // for future multi-tree rotation; start at 0
        next_index: u64,             // number of leaves inserted (== leaf_index of next insert)
        current_root: u256,          // == ZERO[16] when empty
        filled_subtrees: vector<u256>, // length TREE_DEPTH (16). "frontier"
        root_history: vector<u256>,  // ring buffer length ROOT_HISTORY_SIZE (100)
        root_history_index: u64,     // next write position in ring
    }
}
```

> **Representation choice — `u256` not `vector<u8>`.** The native `poseidon_bn254` takes/returns
> `u256`, so we store field elements as `u256` internally. This avoids per-hash byte<->u256 conversion
> and the 32-length asserts that litter the current `merkle.move`. The module exposes
> `vector<u8>`-friendly helpers at the boundary (§4.4) because `transact.move` / `btc_deposit.move`
> currently pass `vector<u8>` commitments and public inputs are big-endian 32-byte. Endianness of the
> u8<->u256 bridge is **big-endian** to match the circuit's public-input encoding and the Solana
> big-endian Poseidon (`crypto.rs:81` `Endianness::BigEndian`).

### 3.3 Capabilities & access control

- `CommitmentTree` mutation must be **package-gated**. Insert functions are `public(package)` so only
  `utxopia::transact` and `utxopia::btc_deposit` can append. (Same trust boundary as the Solana tree,
  which is only mutated by `complete_deposit` and `transact`.)
- Initialization: `public(package) fun create(tree_number, ctx)` called once from the pool
  `initialize` flow; it `transfer::share_object`s the tree. No `AdminCap` required to *insert*
  (inserts are authorized by the proof / SPV path), but creation should be gated behind the same
  init authority that creates the `Pool`.

---

## 4. Function Signatures

### 4.1 Constructor / init

```move
/// Create and share an empty tree. current_root = ZERO[16], next_index = 0,
/// filled_subtrees = [0;16], root_history = [0;100], root_history_index = 0.
public(package) fun create(tree_number: u32, ctx: &mut TxContext)

/// Return the shared object id (for events / linking into Pool).
public fun id(t: &CommitmentTree): address
```

### 4.2 Core insert (internal, u256)

```move
/// Append one leaf. Returns the leaf index it was written to.
/// Aborts if tree full or leaf >= r.
/// PORT OF commitment_tree.rs::insert_leaf (lines 204-233).
public(package) fun insert_leaf(t: &mut CommitmentTree, leaf: u256): u64

/// Hash two field elements as a tree node. parent = Poseidon([l, r]).
/// Wraps sui::poseidon::poseidon_bn254. Asserts l < r and r_in < r before calling.
fun hash_node(left: u256, right: u256): u256

/// ZERO[level] lookup (level in 0..=16).
fun zero_hash(level: u64): u256

/// Push current_root into ring buffer, then set current_root = new_root.
/// PORT OF commitment_tree.rs::update_root (lines 179-184).
fun update_root(t: &mut CommitmentTree, new_root: u256)
```

### 4.3 Root validation (consumed by transact)

```move
/// True if `root` equals current_root or any root in history.
/// PORT OF commitment_tree.rs::is_valid_root (lines 161-176).
public fun is_valid_root(t: &CommitmentTree, root: u256): bool

public fun current_root(t: &CommitmentTree): u256
public fun next_index(t: &CommitmentTree): u64
public fun is_full(t: &CommitmentTree): bool   // next_index >= MAX_LEAVES
```

### 4.4 Byte-boundary helpers (for existing callers)

```move
/// Big-endian 32-byte -> u256, asserting length==32 and value < r.
public(package) fun field_from_be_bytes(b: &vector<u8>): u256

/// u256 -> big-endian 32-byte (left-zero-padded).
public fun field_to_be_bytes(x: u256): vector<u8>

/// Convenience: insert a commitment supplied as 32 BE bytes (used by transact/btc_deposit).
/// Emits commitment_inserted + merkle_root_updated events. Returns leaf index.
public(package) fun insert_commitment_bytes(
    t: &mut CommitmentTree,
    commitment_be: vector<u8>,
): u64
```

> `insert_commitment_bytes` is the drop-in replacement for the old
> `merkle::insert_commitment(pool, commitment)` call sites
> (`transact.move:48`, plus the deposit path). It does: `field_from_be_bytes` → `insert_leaf` →
> emit events.

---

## 5. Algorithm (step by step, porting Solana)

### 5.1 `insert_leaf` (port of `commitment_tree.rs:204-233`)

```
fun insert_leaf(t, leaf):
    assert leaf < r                              # canonicalization guard (§2.2, §7 R4)
    leaf_index = t.next_index
    assert leaf_index < MAX_LEAVES               # TreeFull (commitment_tree.rs:206-208)

    current = leaf
    index   = leaf_index
    for level in 0..16:                          # TREE_DEPTH iterations
        if index % 2 == 0:                       # left child
            t.filled_subtrees[level] = current   # cache for future right sibling
            current = hash_node(current, ZERO[level])
        else:                                    # right child
            current = hash_node(t.filled_subtrees[level], current)
        index = index / 2
    update_root(t, current)                      # ring-buffer push + set current_root
    t.next_index = leaf_index + 1
    return leaf_index
```

This is the **exact** structure of `commitment_tree.rs:210-232` (frontier == `filled_subtrees`).
Each insert performs exactly **16** `poseidon_bn254` calls (one per level). The left/right decision
uses bit `level` of the leaf index, matching the circuit's `path_indices` (where `path_indices[level]
== 0` ⇒ current is left ⇒ `hash(current, sibling)`; see `merkle.circom:31-37`).

### 5.2 `update_root` (port of `commitment_tree.rs:179-184`)

```
fun update_root(t, new_root):
    pos = t.root_history_index % ROOT_HISTORY_SIZE
    t.root_history[pos] = t.current_root        # archive the OLD current root
    t.root_history_index = t.root_history_index + 1
    t.current_root = new_root
```

Note the Solana subtlety being preserved: it stores the **previous** `current_root` into history,
then advances. So after N inserts, `current_root` is the newest and the ring holds the prior 100
roots. `is_valid_root` checks both. (`commitment_tree.rs:162-175`.)

### 5.3 `is_valid_root` (port of `commitment_tree.rs:161-176`)

```
fun is_valid_root(t, root):
    if root == t.current_root: return true
    for h in t.root_history: if h == root: return true
    return false
```

Initialization detail: at creation, `current_root = ZERO[16]` and the 100 history slots are `0`
(`ZERO[0]`). Because `0` is not a reachable real root, the empty slots are harmless. (Matches Solana
`init` zeroing at `commitment_tree.rs:132,138`.)

### 5.4 Consumer change in `transact.move`

`transact.move:24` currently does:
```move
assert_public_input_at(&public_inputs, 0, &pool::latest_root(pool));   // current root ONLY
```
Replace with a **history-aware** check (this is the fix for the front-running/race bug — a deposit
landing between proof-gen and submission must not invalidate the proof):
```move
let proof_root = commitment_tree::field_from_be_bytes(&extract_public_input(&public_inputs, 0));
assert!(commitment_tree::is_valid_root(tree, proof_root), errors::stale_merkle_root());
```
and `transact.move:48` `merkle::insert_commitment(pool, commitments_out[j])` becomes
`commitment_tree::insert_commitment_bytes(tree, commitments_out[j])`.

### 5.5 Consumer change in deposit path

The deposit completion path (the Sui analogue of Solana `complete_deposit.rs`, currently flowing
through `btc_deposit.move` / `btc_light_client.move::new_verified_deposit`) computes
`commitment = Poseidon(npk, token, amount)` and must call `insert_commitment_bytes(tree, commitment)`.
The commitment hashing itself is **module 02 (poseidon-commitment / btc-deposit)** — this module only
consumes the resulting field element. See §8.

---

## 6. Gas / Performance

### 6.1 Back-of-envelope

- **1 insert = 16 `poseidon_bn254(2-element)` calls.** Sui charges native Poseidon by input count;
  a binary Poseidon is one of the cheapest instances. As an order-of-magnitude anchor, Poseidon over
  BN254 is the dominant cost; 16 of them per insert is the floor and is unavoidable for a depth-16
  incremental tree (this is identical to Solana's 16 syscalls in `insert_leaf`). There is **no**
  cheaper correct construction that still matches the circuit — sparse re-hash would be 2^16.
- **Storage writes per insert:** `current_root` (32B), one `filled_subtrees[level]` slot (32B, only
  when the leaf is a left child at that level — but in the worst/most-common single-level case it's
  one slot; the loop only writes `filled_subtrees[level]` on the even branch, so 1 write/insert on
  average for the lowest set-bit transition), `next_index` (8B), one `root_history` slot (32B),
  `root_history_index` (8B). All bounded, O(1) object-size mutation — the object size does **not**
  grow per insert (fixed 16+100 element vectors), so storage rebate accounting is stable.
- **Object size:** `16*32 (frontier) + 100*32 (history) + ~32 (root) + counters ≈ 3.8 KB`, same
  ballpark as the Solana account (`commitment_tree.rs` layout comment lines 53-62). Well within Sui
  object limits.

### 6.2 Mitigations / choices

- **Fixed-length vectors, no `Table`.** Use `vector<u256>` of fixed length 16 / 100. A `sui::table`
  would add per-entry dynamic-field overhead for no benefit (we index by small fixed range). Keep
  everything in the object body for cheap sequential reads in the hash loop.
- **Avoid byte<->u256 churn.** Do the BE-bytes→u256 conversion **once** at the boundary
  (`field_from_be_bytes`), then operate purely on `u256` through the 16-hash loop. The old
  `merkle.move` re-allocated a 64-byte `preimage` vector per insert — gone.
- **No per-insert event spam beyond parity.** Keep `commitment_inserted` (with leaf_index) and
  `merkle_root_updated` events (matching `pool.move:71` / current `events.move`) so the indexer can
  rebuild proofs off-chain; the indexer (`chains/sui/indexer`) must NOT need to recompute Poseidon.
- **batch inserts (transact M outputs):** a 2×2 transact inserts up to 2 leaves = 32 hashes in one
  tx. That is the practical max given the 1x1/1x2/2x1/2x2 catalog cap (locked decision), so worst-case
  per-tx Poseidon load is bounded and small. No need for multi-tx batching.

### 6.3 Canonicalization cost

`field_from_be_bytes` does a 32-byte BE decode + a single `< r` comparison. Negligible. We rely on
`poseidon_bn254` to also abort on `>= r` as defense-in-depth, but we check first to return our own
typed error (`errors::commitment_out_of_field()`) rather than a native abort.

---

## 7. Risks, Edge Cases, Security Pitfalls

| # | Risk | Mitigation |
|---|---|---|
| **R1** | **Zero ladder mismatch** with circuit ⇒ every empty-subtree path is wrong ⇒ deposits unspendable, silently. | Test #U2 recomputes the full ladder from `ZERO[0]=0` via `poseidon_bn254` and asserts the 17 literals in §2.1. CI gate. |
| **R2** | **Node-hash order / arity mismatch** (`Poseidon([l,r])` vs `Poseidon([r,l])` or a 1-input sponge). | Test #U1 asserts `hash_node(1,2) == 0x115cc0f5...189a` (circomlibjs vector, `crypto.rs:588`). Cross-checks ordering AND parameterization in one shot. |
| **R3** | **Left/right rule inverted** (treating odd index as left). | Test #U3: insert leaves at indices 0 and 1, compare resulting root against an SDK-computed root (`commitment-tree.ts`) and against the circuit's `MerkleProofVerifier` for both leaves. |
| **R4** | **Field-element canonicalization.** A caller passes 32 bytes encoding a value `>= r`. Solana *masks* (`reduce_to_field`), which would desync from a circuit that rejects, and is a malleability vector. | **Reject, do not reduce.** `field_from_be_bytes` aborts if `>= r`. Valid commitments are always `< r` (Poseidon outputs). Do NOT port `crypto.rs:59-68`. |
| **R5** | **Root-history race / front-running.** Deposit lands between user proof-gen and transact submission ⇒ `current_root` advances ⇒ proof against the old root rejected. | `is_valid_root` over a 100-deep ring buffer (§5.3); `transact` validates against history not just current (§5.4). 100 roots ≈ comfortable confirmation window. |
| **R6** | **History too shallow under burst.** 100 deposits in the window between proof-gen and submission could evict the proof's root. | Document the 100-root assumption; matches Solana `ROOT_HISTORY_SIZE`. If burst rate demands more, bump `ROOT_HISTORY_SIZE` (constant; object grows linearly). Out of scope to change the constant here — parity first. |
| **R7** | **Integer overflow** on `next_index`/`root_history_index`. | `u64`; `next_index` capped at `MAX_LEAVES=65_536` (abort on full). `root_history_index` increments by 1/insert, bounded by tree capacity (≤65_536) ⇒ never overflows u64; modulo keeps it in range. |
| **R8** | **Tree-full behavior.** Inserting beyond 2^16 corrupts indices. | `insert_leaf` aborts with `errors::tree_full()` when `next_index >= MAX_LEAVES` (port of `commitment_tree.rs:206-208`). |
| **R9** | **Reorg of BTC deposits inserting bad leaves.** Out of scope for THIS module — leaf validity (SPV) is upstream (module 01/02). But: once a leaf is inserted it is permanent (append-only). Therefore the deposit module MUST fully verify SPV *before* calling `insert_commitment_bytes`. Documented dependency (§8). A reorg after insert is handled by the BTC light-client finality depth, not by removing leaves. |
| **R10** | **`Pool` vs tree dual source of truth.** Leaving `pool.latest_root` in place ⇒ two roots that drift. | Remove `latest_root`/`latest_root_index`/`next_leaf_index` from `pool.move`; tree object is canonical. Update all readers. (§8.) |
| **R11** | **Empty-slot collision.** `0` sits in unused history slots and equals `ZERO[0]`; could a forged `root=0` pass `is_valid_root`? | `0` is never a real `current_root` (empty tree root is `ZERO[16]≠0`) and a transact proof with root `0` cannot verify against any real leaf set. Still: optionally seed history with `ZERO[16]` instead of `0` to be explicit. Low risk; note in tests #U5. |
| **R12** | **Determinism of `poseidon_bn254` across Sui versions.** | Pin Sui framework rev in `Move.toml`; the ladder-recompute test (R1) is the canary on any framework Poseidon change. |

---

## 8. Dependencies On Other Modules In This Design Set

| Depends on | Why |
|---|---|
| **Module 02 — Poseidon commitment / BTC deposit completion** | Produces the `commitment = Poseidon(npk, token, amount)` field element that this module appends. This module does NOT compute commitments; it only inserts them. Must use the same `poseidon_bn254` BE convention. |
| **Module 01 — BTC SPV light client** | Gatekeeps deposit insertion: SPV must pass before `insert_commitment_bytes` is called, because inserts are irreversible (R9). |
| **`verifier` (groth16) + `transact`** | Consumer: reads `is_valid_root` for the proof's `public_inputs[0]` and calls `insert_commitment_bytes` for outputs. Requires the §5.4 edits. |
| **`pool.move`** | Must drop `latest_root` / `latest_root_index` / `next_leaf_index` (R10) and the deposit/transact entry points must now also take `&mut CommitmentTree`. |
| **`merkle.move`** | **Deleted/replaced** by this `commitment_tree` module. Remove the SHA256 chain. |
| **`events.move`** | Reuse `commitment_inserted` and `merkle_root_updated` events. |
| **SDK (`packages/sdk-sui` + `sdk/src/commitment-tree.ts`)** | Off-chain mirror must parse the new shared object layout (fields, not the Solana byte layout) to build Merkle proofs. The zero ladder + algorithm are already correct in `commitment-tree.ts`; only the on-chain *parsing* differs (Sui object vs Solana account bytes). |
| **Indexer (`chains/sui/indexer`)** | Subscribes to `commitment_inserted` to maintain off-chain leaf set / proofs; must not recompute roots. |

---

## 9. Test Matrix

### 9.1 Unit (Move `#[test]`, run with `sui move test`)

| ID | Test | Assert |
|---|---|---|
| **U1** | `hash_node(1, 2)` | `== 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a` (circomlibjs / `crypto.rs:588`) |
| **U2** | Recompute zero ladder from `ZERO[0]=0` via `poseidon_bn254` | all 17 values equal §2.1 literals (incl. `ZERO[16]=0x2a7c...7323`) |
| **U3** | Empty tree | `current_root == ZERO[16]`, `next_index == 0`, `is_full == false` |
| **U4** | Insert 1 leaf `L` at index 0 | new root `== Poseidon` fold of `L` with `ZERO[0..15]`; `next_index==1`; old `ZERO[16]` now in history; `is_valid_root(old)==true` |
| **U5** | Insert 2 leaves (index 0,1) | level-0 parent uses `hash_node(L0, L1)` (right-child branch consumes `filled_subtrees[0]==L0`); root matches SDK |
| **U6** | `is_valid_root` over history | after 5 inserts, all 5 prior roots + current return true; a random root returns false; bare `0` returns false |
| **U7** | Ring buffer wrap | after `ROOT_HISTORY_SIZE+5` inserts, the 5 oldest roots evicted (return false), newest 100 still valid |
| **U8** | `field_from_be_bytes` rejects `>= r` | passing `r` and `r+1` (BE) aborts with `commitment_out_of_field` |
| **U9** | `field_from_be_bytes`/`field_to_be_bytes` round-trip | BE bytes ↔ u256 stable; left-zero-padding correct for small values |
| **U10** | Tree-full | force `next_index = MAX_LEAVES`; insert aborts `tree_full` |
| **U11** | Determinism | inserting the same sequence twice (fresh trees) yields identical `current_root` and history |
| **U12** | Left/right at deeper level | insert 3 leaves; verify `filled_subtrees[1]` set on the index-1→level-1 transition and index-2 root correct vs SDK |

### 9.2 Cross-implementation (golden vectors)

| ID | Test | Assert |
|---|---|---|
| **X1** | Insert leaves `[1,2,3,4,5]` into Move tree and into `sdk/src/commitment-tree.ts` | identical `current_root` after each insert (5 checkpoints) |
| **X2** | Same 5-leaf sequence vs Solana `CommitmentTree::insert_leaf` | identical roots (proves 3-way agreement: Move / Solana / SDK) |
| **X3** | For leaf at index `k`, build proof via SDK and run it through `circuits/circom/lib/merkle.circom` `MerkleProofVerifier(16)` | circuit `root` output `== tree.current_root` at the time leaf `k` was the last insert (deposit→transact provability) |

### 9.3 Integration (Sui Move scenario / `chains/sui/scripts/regtest-flow.ts`)

| ID | Test | Assert |
|---|---|---|
| **I1** | Deposit (SPV-verified) inserts commitment, then transact spends it | transact `public_inputs[0]` validates via `is_valid_root`; groth16 verifies; output commitments appended |
| **I2** | Deposit lands between user proof-gen and transact submission (race) | transact still succeeds because the proof's (now-historical) root is in `root_history` (R5) |
| **I3** | Two transacts in same checkpoint each appending 2 outputs | `next_index` advances by 4; all 4 leaves provable; roots monotonic in history |
| **I4** | Indexer rebuild | after N on-chain inserts, indexer reconstructs the same root from `commitment_inserted` events alone |
| **I5** | Stale/forged root rejected | transact with a root never in current/history aborts `stale_merkle_root` |

---

## 10. Effort & Open Questions

### 10.1 Effort estimate (developer-days)

| Task | Days |
|---|---|
| `commitment_tree.move` module (structs, insert_leaf, update_root, is_valid_root, byte helpers) | 1.0 |
| Zero-ladder constants + recompute test (U2) | 0.5 |
| Wire into `transact.move` (history-aware root check) + `btc_deposit` insert path + remove `merkle.move` + prune `pool.move` fields | 1.0 |
| Unit tests U1–U12 | 1.0 |
| Cross-impl golden vectors X1–X3 (incl. SDK + circuit harness) | 1.0 |
| Integration I1–I5 in regtest-flow + indexer parse update | 0.5–1.0 |
| **Total** | **5–6 dev-days** |

(Lower bound 4 if the SDK/circuit harness from the Solana side can be reused directly; the locked
1x1/1x2/2x1/2x2 catalog keeps the proof surface small.)

### 10.2 Open questions

1. **Confirm `poseidon_bn254` == circomlibjs BN254x5.** Test U1/U2 will prove it, but if Sui's native
   Poseidon uses a different round-constant set or domain tag, the entire interop breaks and we'd need
   a Move-level Poseidon (expensive). This is the single biggest unknown — run U1/U2 **first**, before
   building anything else.
2. **`u256` literal endianness sanity:** confirm `poseidon_bn254` treats each `u256` as a field
   element value (not as little-endian bytes). Expected yes (it's `u256`, a numeric type), but verify
   against U1.
3. **Should history slots seed with `ZERO[16]` instead of `0`?** (R11) Cosmetic/defensive; pick one and
   make the SDK parser match.
4. **Multi-tree rotation** (`tree_number`): Solana has `rotate_tree.rs`. Out of scope here, but the
   `tree_number: u32` field is reserved so a future rotation module doesn't require a struct migration.
   Confirm we want it reserved now (cheap) vs added later (object migration cost).
5. **`Pool` coupling:** confirm the team accepts removing `latest_root`/`next_leaf_index` from
   `pool.move` (R10) vs keeping `pool` as a thin forwarder. Recommendation: remove — single source of
   truth.
