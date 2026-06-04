# Spec 04 — Complete-Deposit Wiring (Move)

**Module set:** Sui production hardening
**This spec:** `complete-deposit` — wire SPV-verified BTC deposit → fee math → Poseidon commitment → real Poseidon Merkle insert → double-claim guard → stealth announcement
**Depends on:** Spec 01 (SPV light client), Spec 02 (`verify_transaction` / verified-deposit issuance), Spec 03 (real Poseidon Merkle tree)
**Status:** implementation-ready
**Target:** trustless mainnet parity with Solana `complete_deposit.rs`

---

## 1. Goal & What It Replaces

### 1.1 Goal

Port Solana `contracts/programs/utxopia/src/instructions/complete_deposit.rs::process_complete_deposit` (lines 128–529) to Move, producing a single trustless deposit-completion entry that:

1. Consumes a **real** SPV-verified deposit object produced by Spec 02 (NOT the current trust-everything stub).
2. Extracts `npk` + `ephemeral_pub` trustlessly from the deposit transaction's OP_RETURN (Sol ref: `complete_deposit.rs:341-344`, `utils/bitcoin.rs::get_deposit_op_return` lines 326-352).
3. Extracts the credited amount trustlessly from the SPV-verified output (Sol ref: `complete_deposit.rs:350-386`).
4. Applies protocol fee (bps) + per-token service fee (Sol ref: `complete_deposit.rs:396-399`).
5. Computes the commitment **on-chain**: `Poseidon(npk, ZKBTC_TOKEN_ID, shielded_amount)` (Sol ref: `complete_deposit.rs:401-403`, `utils/crypto.rs::compute_commitment` lines 260-265).
6. Inserts the commitment into the **real Poseidon tree** from Spec 03 (Sol ref: `complete_deposit.rs:405-415`).
7. Records the claimed outpoint to prevent double-claim — replacing the Solana `DepositReceipt` PDA (Sol ref: `complete_deposit.rs:206-243`).
8. Emits the stealth-announcement event (type=0, plaintext amount) + deposit-verified + BTC-origin attestation (Sol ref: `complete_deposit.rs:417-449`).
9. Proves the two-step **deposit → sweep** linkage on-chain (Sol ref: `complete_deposit.rs:333-339`).

Note: zkBTC minting (Sol ref: `complete_deposit.rs:491-504`) has **no Sui analogue** — UTXOpia-Sui has no public token; the commitment in the shielded tree IS the liability. We drop the mint step. Pool/token accounting counters are kept as object fields.

### 1.2 What current Sui code this replaces / rewrites

| Current Sui code | Problem | Action |
|---|---|---|
| `btc_light_client.move::new_verified_deposit` (lines 16-40) | **ZERO verification** — only length asserts. Anyone can mint a `VerifiedBtcDeposit` and steal funds. | Deleted/replaced by Spec 02's real verified-deposit issuance. This spec consumes that real object. |
| `btc_deposit.move::complete_verified_deposit` (lines 27-70) | Trusts a forgeable object; no fee math; sets root via SHA256 chain (`merkle.move`); does not compute commitment on-chain (takes it as input); does not prove deposit→sweep linkage; OP_RETURN split is naive. | **Rewritten** as the entry described here. |
| `btc_deposit.move::BtcDepositRegistry.claimed_outpoints: vector<vector<u8>>` + `contains_claim` O(n) scan (lines 14-17, 76-86) | O(n) linear scan per claim — unbounded gas, DoS as deposits grow. | Replaced by a `Table`-backed dedup keyed by outpoint (see §2.3). |
| `merkle.move::derive_next_root` SHA256 chain (lines 21-28) | Root unrelated to circuit. | Replaced by Spec 03's real Poseidon tree; this spec only calls `merkle::insert_commitment`. |

---

## 2. Sui-Native Data Model

### 2.1 Object-model deltas vs. Solana PDAs

| Solana (PDA) | Sui equivalent | Notes |
|---|---|---|
| `VerifiedTransaction` PDA owned by btc-light-client | `VerifiedBtcDeposit` (hot-potato / owned object) from Spec 02 | Spec 02 issues a real one; here it is *consumed by value* (destroyed), which is itself a single-use guarantee — but see §7.4: object destruction alone does NOT prevent double-claim across different verified objects of the same outpoint. We still need the outpoint table. |
| `DepositReceipt` PDA (`create_pda_account`, init disc) — existence = "already claimed" | `Table<vector<u8>, bool>` (or `Bag`) inside `BtcDepositRegistry` shared object, keyed by `outpoint_key` | Sui has no "PDA exists ⇒ already done" idiom; use a `Table` membership check + insert. |
| `UtxoRecord` PDA (pool BTC UTXO) | `Table<vector<u8>, UtxoRecord>` keyed by `txid||vout` inside pool or a dedicated `UtxoSet` shared object | Needed by redemption (Spec on Ika withdrawal). Kept as struct in a table. |
| `PoolState` PDA (writable, counters) | `Pool` shared object (`pool.move`) extended with counters | Counters become struct fields. |
| `TokenConfig` PDA (token_id, fees, totals) | `TokenConfig` field/object | For mainnet parity keep a `TokenConfig` struct holding `token_id: u256`, `service_fee_sats: u64`, `total_shielded: u128`, `accumulated_fees: u128`. For the BTC-only Sui MVP this MAY be inlined into `Pool` as `btc_token_id`, `btc_service_fee_sats`. Spec keeps it as a sub-struct for forward-compat. |
| `CommitmentTree` PDA | `CommitmentTree` shared object from Spec 03 | Passed `&mut`. |
| `LightClient` PDA (tip height) | `LightClient` shared object from Spec 01/02 | Passed `&` (read tip for confirmations). |

### 2.2 Capabilities

- No `AdminCap` required for `complete_deposit` — it is **permissionless** (anyone can submit a valid SPV-verified deposit; correctness is enforced cryptographically, matching the trustless target). On Solana the authority signer is only a rent payer; on Sui the gas payer fills that role, so we drop the authority gate.
- `Pool.paused` is still checked (`pool::assert_not_paused`).

### 2.3 New / extended structs

```move
module utxopia::btc_deposit {
    use sui::table::{Self, Table};

    /// Replaces vector<vector<u8>> claimed_outpoints with O(1) membership.
    public struct BtcDepositRegistry has key {
        id: UID,
        /// key = outpoint_key(txid, vout) (36 bytes), value = unit marker
        claimed: Table<vector<u8>, bool>,
        claimed_count: u64,
    }

    /// Pool-controlled BTC UTXO, recorded for later sweeping/redemption.
    /// Mirrors Solana UtxoRecord (state/utxo_record.rs).
    public struct UtxoRecord has store, copy, drop {
        txid: vector<u8>,   // 32 bytes, internal byte order
        vout: u32,
        amount_sats: u64,
        status: u8,         // 0 = Unspent
    }

    public struct UtxoSet has key {
        id: UID,
        utxos: Table<vector<u8>, UtxoRecord>, // key = txid||vout_le (36 bytes)
    }
}
```

`TokenConfig` (BTC) — minimal:

```move
public struct BtcTokenConfig has store {
    token_id: u256,          // = ZKBTC_TOKEN_ID = 0x7a627463
    service_fee_sats: u64,   // flat per-deposit service fee
    total_shielded: u128,
    accumulated_fees: u128,
}
```

`Pool` extension (added in `pool.move`, set at init / via AdminCap):

```move
// added fields
min_deposit_sats: u64,
max_deposit_sats: u64,
deposit_fee_bps: u16,     // protocol fee, <= 10_000
deposit_count: u64,
total_shielded: u128,
total_utxo_sats: u128,
btc_token_config: BtcTokenConfig,
// optional: pool_script: vector<u8>  // expected sweep output scriptPubKey (P2TR of Ika wallet)
```

---

## 3. Function Signatures

### 3.1 Entry

```move
/// Permissionless. Consumes a real SPV-verified deposit (Spec 02), completes
/// the shielded deposit. Aborts on any inconsistency.
public entry fun complete_deposit(
    pool: &mut Pool,
    registry: &mut BtcDepositRegistry,
    utxo_set: &mut UtxoSet,
    tree: &mut CommitmentTree,            // Spec 03
    light_client: &LightClient,           // Spec 01/02 — tip height for confirmations
    verified_deposit: VerifiedBtcDeposit, // Spec 02 — consumed by value
    ctx: &mut TxContext,
)
```

`VerifiedBtcDeposit` shape (from Spec 02; this spec defines the contract it relies on). It MUST carry everything needed so this entry re-derives nothing from unverified data:

```move
public struct VerifiedBtcDeposit has key {  // owned, single-use
    id: UID,
    block_height: u64,
    // sweep tx (the SPV-included tx whose Merkle inclusion Spec 02 proved):
    sweep_txid: vector<u8>,        // 32, internal byte order
    sweep_raw_tx: vector<u8>,      // full raw bytes, hash-checked == sweep_txid by Spec 02
    // deposit tx (the user-broadcast tx carrying OP_RETURN):
    deposit_txid: vector<u8>,      // 32, internal byte order
    deposit_raw_tx: vector<u8>,    // EMPTY iff direct_to_pool
    direct_to_pool: bool,          // true ⇒ sweep IS the deposit tx
    // optional pool-script binding for sweep output selection:
    pool_script: vector<u8>,       // empty ⇒ first non-OP_RETURN positive output
}
```

> Design choice: Spec 02 hands over **raw tx bytes already hash-bound to the SPV-proven txids**, and this module re-parses them. This keeps tx parsing logic (OP_RETURN extraction, output selection, input linkage) in one place and mirrors Solana, where `complete_deposit.rs` reparses the ChadBuffer bytes after checking `compute_tx_hash == txid` (lines 282-327). Spec 02 MUST assert `double_sha256(sweep_raw_tx) == sweep_txid` and (when not direct) `double_sha256(deposit_raw_tx) == deposit_txid` before constructing the object, so re-parsing here is safe.

### 3.2 Internal helpers (this module)

```move
// Outpoint dedup key (Sol ref: btc_deposit.move::outpoint_key lines 88-95)
fun outpoint_key(txid: &vector<u8>, vout: u32): vector<u8>

// Fee math (Sol ref: complete_deposit.rs:396-399)
fun apply_deposit_fees(amount_sats: u64, deposit_fee_bps: u16, service_fee: u64): (u64 /*shielded*/, u64 /*total_fee*/)

// Commitment (Sol ref: crypto.rs::compute_commitment lines 260-265)
fun compute_commitment(npk: u256, token_id: u256, amount_sats: u64): u256

// canonical conversions (see §5.4)
fun field_from_be32(b: &vector<u8>): u256          // big-endian 32 bytes -> u256, assert < r
fun field_to_be32(x: u256): vector<u8>             // u256 -> 32 big-endian bytes
```

### 3.3 Bitcoin tx parsing (shared lib — `utxopia::bitcoin`)

Ported from `utils/bitcoin.rs`. Used by this spec AND Spec 02. Define once:

```move
module utxopia::bitcoin {
    public struct TxOutput has copy, drop { value: u64, script_pubkey: vector<u8> }
    public struct TxInput  has copy, drop { prev_txid: vector<u8>, prev_vout: u32 }

    public fun parse_outputs(raw_tx: &vector<u8>): vector<TxOutput>;   // Sol: ParsedTransaction::outputs
    public fun parse_inputs(raw_tx: &vector<u8>): vector<TxInput>;     // Sol: ParsedTransaction::inputs
    public fun find_deposit_op_return(raw_tx: &vector<u8>): (bool, vector<u8> /*ephemeral*/, vector<u8> /*npk*/); // Sol: get_deposit_op_return 326-352
    public fun find_deposit_output_with_vout(raw_tx: &vector<u8>): (bool, TxOutput, u32);     // Sol 489-496
    public fun find_output_by_script(raw_tx: &vector<u8>, script: &vector<u8>): (bool, TxOutput, u32); // Sol 499-506
    public fun find_deposit_output(raw_tx: &vector<u8>): (bool, TxOutput);                     // Sol 483-486
    public fun has_input_with_prev_txid(raw_tx: &vector<u8>, target_txid: &vector<u8>): bool;  // Sol 531-538
    fun read_varint(data: &vector<u8>, offset: u64): (u64 /*value*/, u64 /*new_offset*/);      // Sol 627-653
}
```

> Spec 01/02 likely already define `utxopia::bitcoin` (double_sha256, varint). If so, this module **extends** it; do not duplicate `read_varint`/`double_sha256`.

---

## 4. Algorithm (step by step, with Solana cross-references)

`complete_deposit(...)`:

1. **Pause check.** `pool::assert_not_paused(pool)`. (Sol: `complete_deposit.rs:187-189`.)

2. **Destructure verified deposit** (consume by value, `object::delete(id)`): pull `block_height, sweep_txid, sweep_raw_tx, deposit_txid, deposit_raw_tx, direct_to_pool, pool_script`. (Sol analogue: reading the `VerifiedTransaction` PDA + ChadBuffers, lines 245-327.)

3. **Confirmations.** Read `tip = light_client::tip_height(light_client)`. Compute
   `confirmations = if block_height > tip { 0 } else { tip - block_height + 1 }`.
   `assert!(confirmations >= REQUIRED_CONFIRMATIONS, E_INSUFFICIENT_CONFIRMATIONS)`.
   Mainnet `REQUIRED_CONFIRMATIONS = 6`. (Sol: `complete_deposit.rs:262-274`, const lines 56-60.)

4. **Resolve deposit_raw_tx.** If `direct_to_pool`: assert `deposit_txid == sweep_txid` (Sol 308-312) and use `sweep_raw_tx` as the deposit tx. Else use `deposit_raw_tx` (Spec 02 already hash-checked it). (Sol 294-327.)

5. **Deposit→sweep linkage.** If `!direct_to_pool`: assert `bitcoin::has_input_with_prev_txid(&sweep_raw_tx, &deposit_txid)`. This proves the chain deposit→sweep on-chain (the sweep, which is SPV-included, spends the deposit's outpoint). (Sol: `complete_deposit.rs:333-339`.) See §7.1 for the malleability caveat and the `prev_vout` hardening note.

6. **Extract OP_RETURN.** `(ok, ephemeral_pub, npk) = bitcoin::find_deposit_op_return(&deposit_raw_tx)`. `assert!(ok, E_INVALID_STEALTH_OP_RETURN)`. Both 32 bytes. (Sol 341-344.)

7. **Select credited output + vout** from the **sweep** tx (the SPV-proven tx that pays the pool):
   - If `pool_script` non-empty: `find_output_by_script(&sweep_raw_tx, &pool_script)` → `(output, sweep_vout)`; abort if absent. This binds the credit to the Ika-wallet P2TR. (Sol 350-368.)
   - Else: `find_deposit_output_with_vout(&sweep_raw_tx)` (first non-OP_RETURN, value>0). (Sol 369-373.)
   - `amount_sats = output.value`.
   - `original_deposit_sats`: if `direct_to_pool` → `amount_sats`; else `find_deposit_output(&deposit_raw_tx).value` (pre-sweep-fee user amount, for the indexer event). (Sol 374-386.)

8. **Bounds.** `assert!(amount_sats >= pool.min_deposit_sats, E_AMOUNT_TOO_SMALL)`; `assert!(amount_sats <= pool.max_deposit_sats, E_AMOUNT_TOO_LARGE)`. (Sol 388-394.)

9. **Fees.**
   `protocol_fee = (amount_sats as u128 * deposit_fee_bps as u128 / 10_000) as u64;`
   `total_fee = protocol_fee + service_fee;` (`service_fee = pool.btc_token_config.service_fee_sats`)
   `assert!(amount_sats > total_fee, E_FEE_EXCEEDS_AMOUNT);`  // prevents underflow / zero-value note
   `shielded_amount = amount_sats - total_fee;`
   (Sol 396-399 — note Solana relied on `checked_sub`; Move aborts on `u64` underflow natively, but the explicit guard yields a clean domain error.)

10. **Double-claim guard.** `let key = outpoint_key(&deposit_txid, deposit_vout);` where `deposit_vout` is the vout of the user's deposit output in the deposit tx (for `direct_to_pool` use `sweep_vout`; for two-step use the deposit-tx output index — see §7.3). `assert!(!table::contains(&registry.claimed, key), E_BTC_DEPOSIT_ALREADY_CLAIMED); table::add(&mut registry.claimed, key, true); registry.claimed_count = registry.claimed_count + 1;` (Sol: DepositReceipt PDA, 206-243; key dedups on the **deposit txid+vout**, the immutable user outpoint, not the malleable sweep txid — see §7.1.)

11. **Compute commitment on-chain.**
    `let npk_f = field_from_be32(&npk);`
    `let token_id = pool.btc_token_config.token_id; // = ZKBTC_TOKEN_ID`
    `let commitment_u256 = compute_commitment(npk_f, token_id, shielded_amount);`
    `let commitment = field_to_be32(commitment_u256);` (Sol 401-403.)

12. **Insert into real Poseidon tree (Spec 03).**
    `let leaf_index = merkle::insert_commitment(tree, commitment_u256);`
    `assert!(merkle::has_capacity_after(tree), E_TREE_FULL)` — or insert returns abort on full. (Sol 405-415.) Spec 03 maintains the incremental root; emits `MerkleRootUpdated`.

13. **Record pool UTXO.**
    `let utxo_key = outpoint_key(&sweep_txid, sweep_vout);`
    `assert!(!table::contains(&utxo_set.utxos, utxo_key), E_UTXO_EXISTS);`
    add `UtxoRecord { txid: sweep_txid, vout: sweep_vout, amount_sats, status: 0 }`. (Sol 454-489.)

14. **Emit events** (Sol 417-452):
    - `stealth_announcement(type=0 deposit, ephemeral_pub, amount_le = shielded_amount as u64 LE, commitment, leaf_index as u32, token_id_be32)`.
    - `btc_deposit_verified(pool_id, leaf_index, deposit_txid, deposit_vout, amount_sats, ephemeral_pub, npk, commitment)` (keep existing event shape from `events.move`).
    - `deposit_verified_meta(sweep_txid, deposit_txid, amount_sats, leaf_index, original_deposit_sats)`.
    - `btc_origin_attestation(block_height, deposit_txid, sweep_vout, commitment, amount_sats)` — for third-party auditor association sets.
    - `shield_meta(amount_sats, total_fee, token_id)`.

15. **Update counters** (Sol 506-524): `pool.deposit_count += 1; pool.total_shielded += shielded_amount; pool.total_utxo_sats += amount_sats; token_config.total_shielded += shielded_amount; token_config.accumulated_fees += total_fee;`

16. Done. (No zkBTC mint — see §1.1.)

---

## 5. Crypto Primitives & Exact Parameters

### 5.1 Poseidon (MUST match circom + Solana)

- **Curve/field:** BN254 scalar field `Fr`, modulus
  `r = 21888242871839275222246405745257275088548364400416034343698204186575808495617`
  (`0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001`).
- **Commitment hash:** `Poseidon(3)` over `[npk, token, amount]` — confirmed from circuit `circuits/circom/lib/joinsplit_commitment.circom` lines 14-26 and Solana `crypto.rs::compute_commitment` (`poseidon3_hash`). circomlib Poseidon with `nInputs=3`, t=4, the same constants snarkjs/circomlibjs use.
- **Sui native:** `sui::poseidon::poseidon_bn254(data: &vector<u256>): u256`. Sui's implementation uses the circomlib/`light-poseidon` constants (BN254, the standard "Poseidon" used by snarkjs), so it matches circom. **Verify with the cross-language test vectors in §9 before trusting parity** — this is the single highest-risk parity assumption.
  - Cross-check vector (from Solana `crypto.rs` test `test_poseidon3_vs_circomlibjs`): `Poseidon([1,2,3]) = 0x0e7732d89e6939c0ff03d5e58dab6302f3230e269dc5b968f725df34ab36d732`.
  - Poseidon2 vector: `Poseidon([1,2]) = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`.

### 5.2 Field-element inputs to `poseidon_bn254`

Each input is a `u256` that MUST be a canonical field element (`< r`).

- **npk:** comes from the deposit OP_RETURN as 32 big-endian bytes. The SDK generates `npk` as a BN254 field element, so the 32 bytes are already `< r`. Convert with `field_from_be32` and **assert `< r`** (do not silently reduce — a malicious OP_RETURN with `npk >= r` must abort, NOT be reduced, otherwise two different OP_RETURN payloads could map to the same field element and break the deposit↔announcement binding). This is stricter and safer than Solana's `reduce_to_field` (`crypto.rs:59-68`), which masks the top nibble; we can afford a hard assert because the honest SDK always emits canonical npks.
- **token_id:** `ZKBTC_TOKEN_ID = 0x7a627463` ("zkbtc" as u32). As a `u256` literal this is `0x7a627463` (= 2_053_465_187 decimal). It is trivially `< r`. Stored in `BtcTokenConfig.token_id`. (Matches circuit `token` signal which is the raw integer, and `contracts/scripts/test-user-flows.ts:111` `ZKBTC_TOKEN_ID = 0x7a627463n`.)
- **amount:** `shielded_amount: u64` widened to `u256`. The circuit treats `amount` as the integer value of sats. Solana encodes it as big-endian in the low 8 bytes of a 32-byte field then feeds to Poseidon (`crypto.rs:261-264`), which is numerically identical to the plain integer. In Move just pass `(shielded_amount as u256)` directly to `poseidon_bn254` — same field element. **Do not** byte-pack; pass the integer.

```move
fun compute_commitment(npk: u256, token_id: u256, amount_sats: u64): u256 {
    let mut v = vector::empty<u256>();
    vector::push_back(&mut v, npk);
    vector::push_back(&mut v, token_id);
    vector::push_back(&mut v, (amount_sats as u256));
    sui::poseidon::poseidon_bn254(&v)
}
```

### 5.3 Commitment byte representation (for events / cross-module)

The commitment `u256` must be serialized consistently for events and for Spec 03's tree, and must match the SDK's `commitment-tree.ts` which builds a bigint via big-endian byte accumulation (`result = (result << 8) | byte`, lines 24, 195). Therefore:

- **Canonical commitment bytes = 32-byte big-endian of the `u256`.** Use `field_to_be32`.
- Spec 03's tree should store/hash `u256` directly (preferred — Poseidon over `u256` avoids byte juggling). Events emit `field_to_be32(commitment)`.

```move
fun field_to_be32(x: u256): vector<u8> {
    let mut out = vector::empty<u8>();
    let mut i: u8 = 0;
    while (i < 32) {
        let shift = (8 * (31 - (i as u64))) as u8;
        vector::push_back(&mut out, (((x >> shift) & 0xff) as u8));
        i = i + 1;
    };
    out
}
fun field_from_be32(b: &vector<u8>): u256 {
    assert!(vector::length(b) == 32, E_INVALID_COMMITMENT);
    let mut x: u256 = 0;
    let mut i = 0;
    while (i < 32) { x = (x << 8) | (*vector::borrow(b, i) as u256); i = i + 1; };
    assert!(x < BN254_FR_MODULUS, E_NON_CANONICAL_FIELD); // hard reject, no reduce
    x
}
```

> `BN254_FR_MODULUS` as a `u256` constant: `0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001`.

### 5.4 amount LE bytes in stealth announcement

Solana emits `shielded_amount.to_le_bytes()` (8 bytes LE) for deposit announcements, plaintext (`complete_deposit.rs:420`, `events::emit_stealth_announcement`). Preserve **little-endian u64** for the announcement amount field so the SDK scanner (`scanUnifiedNotes`) decodes identically. (Contrast: the commitment field uses big-endian 32 bytes.) Document both endiannesses explicitly in the event struct.

---

## 6. Gas / Performance

1. **Outpoint dedup:** the current `vector` + linear `contains_claim` (`btc_deposit.move:76-86`) is O(n) and unbounded → replace with `sui::table::Table`, O(1). Same for UTXO records. **Required**, not optional, for mainnet.
2. **Tx re-parsing cost:** parsing raw tx bytes (varint loops over inputs/outputs) is the main per-call cost. Bound it: cap `raw_tx` length (e.g. `MAX_RAW_TX = 100_000` bytes) and cap input/output counts (e.g. `MAX_IO = 1024`) to prevent a griefer from submitting a pathological tx that blows the per-tx computation budget. Sweep/deposit txs are small (<2 KB typically); a generous cap is fine.
3. **Poseidon:** native `poseidon_bn254` is cheap relative to Move-level looping. The Merkle insert (Spec 03) does `tree_depth` (16) Poseidon hashes per insert — the dominant cost. Acceptable. Ensure Spec 03 uses incremental insertion (cache filled-subtree nodes) rather than recomputing the whole tree.
4. **Avoid copying raw_tx repeatedly:** parsing helpers should take `&vector<u8>` and return small structs/iterate, not clone the buffer per output (Sol uses zero-copy slices; Move can't slice cheaply but can index in place with offset arithmetic — implement `read_varint(data, offset)` returning a new offset rather than re-slicing).
5. **Object size:** `VerifiedBtcDeposit` carries full raw tx bytes (up to ~2-4 KB for two txs). Owned object; fine. It is consumed/deleted in this call (storage rebate).

---

## 7. Risks, Edge Cases, Security Pitfalls

### 7.1 Transaction malleability — dedup key choice (HIGH)
The **sweep** txid is set by our backend and is effectively non-malleable in practice, but the **deposit** txid (user-broadcast) could in principle be malleated before confirmation (segwit makes the txid itself non-malleable for segwit inputs, but legacy/edge cases exist). The double-claim key must be the thing that is hard to forge into a second distinct credit:
- Key the dedup `Table` on `(deposit_txid, deposit_vout)` — the **outpoint actually consumed**, mirroring Solana's `DepositReceipt::SEED + deposit_txid`. Two different sweeps cannot both spend the same deposit outpoint (Bitcoin consensus prevents double-spend of an outpoint), so the linkage check (step 5) + outpoint dedup together guarantee a deposit credits at most once. **The dedup MUST be on the deposit outpoint, never on the sweep txid alone.** (Sol relies on `deposit_txid`; we additionally bind vout.)
- Harden the linkage check beyond Solana: Solana only checks `find_input_with_prev_txid` (any input referencing the deposit txid). Prefer matching `(prev_txid == deposit_txid && prev_vout == deposit_vout)` to bind the specific funding outpoint, not merely "some input touches that tx." Add `has_input_with_prev_outpoint(raw_tx, txid, vout)`.

### 7.2 Forged `VerifiedBtcDeposit` (CRITICAL — the whole point)
Spec 02 MUST be the **only** constructor of `VerifiedBtcDeposit`, and `new_verified_deposit` (`btc_light_client.move:16`) MUST be deleted or made `public(package)`-restricted to the Spec-02 verification path that actually runs SPV. If any public path can mint this object with arbitrary fields, an attacker mints commitments for free. This spec assumes Spec 02 closes that hole; reviewers must confirm there is no residual public constructor.

### 7.3 vout ambiguity between deposit-tx and sweep-tx (MEDIUM)
- `sweep_vout` = index in the **sweep** tx of the pool-credited output (used for `UtxoRecord` + `btc_origin_attestation`).
- `deposit_vout` = index in the **deposit** tx of the user's funding output (used for the dedup key). In `direct_to_pool` mode, deposit tx == sweep tx, so `deposit_vout == sweep_vout`. In two-step mode they differ. Spec 02 should carry `deposit_vout` explicitly in `VerifiedBtcDeposit`, OR this module derives it via `find_deposit_output_with_vout(&deposit_raw_tx)`. Pick one and document; recommended: **carry it in the verified object** to avoid re-deriving an attacker-influenced index.

### 7.4 Object-destruction is not idempotency (MEDIUM)
Consuming `VerifiedBtcDeposit` by value prevents replaying *that exact object*, but Spec 02 could (if it allows) mint two verified objects for the same deposit (e.g., two SPV proofs in two different blocks after a reorg, or simply called twice). The **outpoint Table** is the real idempotency guarantee. Do not rely on object consumption alone.

### 7.5 Integer overflow / underflow (MEDIUM)
- `amount_sats as u128 * deposit_fee_bps as u128` — widen to `u128` before multiply (`deposit_fee_bps <= 10_000`, `amount <= 21e6*1e8 < 2^51`, product `< 2^65` → fits u128). Down-cast to u64 after `/10_000` is safe.
- `shielded_amount = amount_sats - total_fee` — guard `amount_sats > total_fee` BEFORE subtract (Move aborts on u64 underflow, but explicit guard → clean error).
- Counters `total_shielded`, `total_utxo_sats`, `accumulated_fees` as `u128` to avoid realistic overflow.

### 7.6 Non-canonical field elements (MEDIUM)
`field_from_be32(npk)` MUST hard-assert `< r` (§5.2). Do NOT replicate Solana's lossy `reduce_to_field` top-nibble mask (`crypto.rs:59-68`) — that allows two distinct OP_RETURN payloads to collapse to one field element, weakening the binding between the on-chain announcement and the note the user can spend. Honest SDK npks are always canonical, so a hard reject only blocks malformed deposits.

### 7.7 OP_RETURN parsing edge cases (LOW/MEDIUM)
- Support both direct-push (`0x6a 0x40 <64>`) and PUSHDATA1 (`0x6a 0x4c 0x40 <64>`) exactly as Solana (`bitcoin.rs:331-344`). Reject anything else (wrong length, other push opcodes).
- Multiple OP_RETURNs: take the **first** valid 64-byte deposit OP_RETURN (Sol iterates and returns first match). Standardness allows only one OP_RETURN, but parse defensively.
- Ensure `find_deposit_output_with_vout` skips OP_RETURN and zero-value outputs (Sol 489-496).

### 7.8 Confirmation / reorg interaction (MEDIUM)
Confirmations are computed against the light-client tip at call time (step 3). If a reorg later orphans `block_height`, the deposit is already credited. This matches Solana's model and is mitigated by `REQUIRED_CONFIRMATIONS = 6`. The SPV inclusion proof (Spec 02) is against the canonical chain Spec 01 tracks; a reorg deeper than 6 is out of threat scope. Document this as an accepted assumption.

### 7.9 `direct_to_pool` self-consistency (LOW)
When `direct_to_pool`, assert `deposit_txid == sweep_txid` (Sol 308-312) and **skip** the input-linkage check (the deposit IS the SPV-included pool UTXO). Failing to skip would always abort.

### 7.10 Empty / malformed raw_tx (LOW)
Parser must reject `raw_tx.len() < 10`, truncated varints, offsets running past the buffer (Sol `ParsedTransaction::parse` bounds checks throughout 374-450). Abort, do not panic-index.

---

## 8. Dependencies on Other Modules (this design set)

| Dependency | What this spec needs |
|---|---|
| **Spec 01 — light client** | `light_client::tip_height(&LightClient): u64` for confirmation count. |
| **Spec 02 — verify_transaction / verified deposit** | The ONLY real constructor of `VerifiedBtcDeposit`; must hash-bind `sweep_raw_tx`/`deposit_raw_tx` to the SPV-proven txids and carry `block_height`, `deposit_vout`, `direct_to_pool`, `pool_script`. Must delete/seal the stub `new_verified_deposit`. |
| **Spec 03 — Poseidon Merkle tree** | `merkle::insert_commitment(tree: &mut CommitmentTree, commitment: u256): u64 (leaf_index)`; capacity check; emits `MerkleRootUpdated`; root MUST equal the circom circuit's root (Poseidon arity-2, depth 16, defined zero-subtree constants). This spec only inserts. |
| `utxopia::bitcoin` (shared lib) | tx parsing helpers (§3.3). Co-owned with Spec 02. |
| `utxopia::pool` | extended counters + bounds + fee bps + token config + `assert_not_paused`. |
| `utxopia::events` | extend with `deposit_verified_meta`, `btc_origin_attestation`, `shield_meta`, `stealth_announcement` (keep existing `btc_deposit_verified`, `commitment_inserted`). |
| `utxopia::errors` | add new error codes (§ below). |

New error codes to add to `errors.move`:
`E_INSUFFICIENT_CONFIRMATIONS`, `E_AMOUNT_TOO_SMALL`, `E_AMOUNT_TOO_LARGE`, `E_FEE_EXCEEDS_AMOUNT`, `E_INVALID_STEALTH_OP_RETURN`, `E_NON_CANONICAL_FIELD`, `E_TREE_FULL`, `E_UTXO_EXISTS`, `E_DEPOSIT_LINKAGE_FAILED`, `E_INVALID_RAW_TX`. (Reuse existing `E_BTC_DEPOSIT_ALREADY_CLAIMED`, `E_INVALID_COMMITMENT`, `E_INVALID_BTC_DEPOSIT`, `E_POOL_PAUSED`.)

---

## 9. Test Matrix

### 9.1 Unit — crypto / parity (BLOCKING — gate the whole port on these)
- `poseidon_bn254([1,2,3]) == 0x0e7732d89e6939c0ff03d5e58dab6302f3230e269dc5b968f725df34ab36d732`. If this fails, Sui Poseidon ≠ circom and the design is invalid.
- `poseidon_bn254([1,2]) == 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`.
- `compute_commitment(npk, 0x7a627463, amount)` matches SDK `computeJoinSplitCommitmentSync(npk, 0x7a627463n, amount)` for ≥3 vectors (export from `sdk/src/poseidon.ts`).
- `field_from_be32`/`field_to_be32` round-trip; reject `>= r`; reject `len != 32`.

### 9.2 Unit — bitcoin parsing (port Solana `bitcoin.rs` tests verbatim)
- varint: 0x00→0, 0xfc→252, 0xfd0001→256, 0xfe.., 0xff...
- deposit OP_RETURN: direct push (0x6a 0x40), PUSHDATA1 (0x6a 0x4c 0x40), wrong size rejected.
- `find_deposit_output_with_vout`: single output; OP_RETURN at vout 0 → returns vout 1; multiple outputs → first; zero-value skipped; all-OP_RETURN → none.
- `find_output_by_script`: exact match, first-match, no-match, withdrawal pattern.
- `has_input_with_prev_outpoint`: matches `(txid,vout)`; rejects matching txid but wrong vout (hardening over Sol).
- truncated/empty tx → abort cleanly.

### 9.3 Unit — fee math
- `apply_deposit_fees(100_000, 30 bps, 500)` → protocol=300, total=800, shielded=99_200.
- `deposit_fee_bps=0, service_fee=0` → shielded == amount.
- `total_fee >= amount` → abort `E_FEE_EXCEEDS_AMOUNT`.
- max amount (2.1e15 sats) * 10_000 bps no overflow (u128 path).

### 9.4 Integration — happy paths
- **Direct-to-pool deposit:** verified object with `direct_to_pool=true`, OP_RETURN present, amount in bounds → commitment inserted, leaf_index 0, root updated by Spec 03, outpoint recorded, UTXO recorded, all 5 events emitted, counters incremented.
- **Two-step deposit→sweep:** deposit tx (OP_RETURN) + sweep tx that spends deposit outpoint → linkage passes, `original_deposit_sats` reflects deposit-tx output, `amount_sats` reflects sweep pool output, fees applied.
- **pool_script binding:** sweep with two outputs (user + pool P2TR); `pool_script` set → credits the pool output, correct `sweep_vout`.

### 9.5 Integration — adversarial / aborts
- **Double-claim:** same `(deposit_txid, deposit_vout)` twice → second aborts `E_BTC_DEPOSIT_ALREADY_CLAIMED`. Distinct sweep txid but same deposit outpoint → still aborts (proves dedup keys on deposit outpoint, §7.1).
- **Insufficient confirmations:** `block_height` within 5 of tip → abort.
- **Below min / above max:** abort with correct codes.
- **Missing OP_RETURN / malformed (32-byte) OP_RETURN:** abort `E_INVALID_STEALTH_OP_RETURN`.
- **Non-canonical npk (`>= r`):** abort `E_NON_CANONICAL_FIELD`.
- **Two-step with sweep NOT spending deposit outpoint:** abort `E_DEPOSIT_LINKAGE_FAILED`.
- **`direct_to_pool=true` but `deposit_txid != sweep_txid`:** abort.
- **Paused pool:** abort `E_POOL_PAUSED`.
- **Tree full** (depth-16 capacity, hard to reach in test — unit-test Spec 03 capacity path instead, or temporarily small tree): abort `E_TREE_FULL`.

### 9.6 E2E (regtest, extends `chains/sui/scripts/regtest-flow.ts`)
- Real regtest deposit → Spec 02 verify → `complete_deposit` → SDK scans the emitted stealth announcement, reconstructs the note, and the locally-computed Merkle root equals on-chain `pool.latest_root`. This is the end-to-end parity proof that the Poseidon tree + commitment match the circuit.

---

## 10. Effort Estimate & Open Questions

### Effort: **4–6 developer-days**
- Day 1: `utxopia::bitcoin` tx-parsing port + unit tests (largest chunk; port `bitcoin.rs` tests verbatim).
- Day 2: Poseidon parity vectors, `compute_commitment`, field conversions, fee math.
- Day 3: `complete_deposit` entry wiring + Table-based dedup/UTXO + events; depends on Spec 02/03 interfaces (may need stubs if those land later).
- Day 4: integration tests (happy + adversarial).
- Day 5–6: E2E regtest wiring, SDK root-parity check, review hardening. Buffer for Poseidon-parity surprises.

### Open Questions
1. **Sui Poseidon constant set:** Does `sui::poseidon::poseidon_bn254` use the exact circomlib/snarkjs Poseidon constants (it should — confirm the §9.1 vectors pass on a real Sui devnet/test before committing). If Sui uses a different parameterization, the ENTIRE deposit/transact design breaks. **This must be validated first.**
2. **Where does `deposit_vout` come from** — carried in `VerifiedBtcDeposit` by Spec 02, or derived here? Recommend carried (§7.3). Needs Spec 02 sign-off.
3. **Token config scope:** inline BTC-only into `Pool`, or full `TokenConfig` object for future multi-token (USDC/USDT parity)? Sui MVP is BTC-only; recommend inline `BtcTokenConfig` now, refactor later.
4. **`pool_script` provisioning:** is the Ika-wallet sweep P2TR known at pool-init (set via AdminCap), or must it be configurable post-DKG (matching Solana `set_pool_config`)? Affects whether `pool_script` binding is mandatory or optional on mainnet. Recommend mandatory on mainnet for the credited-output binding.
5. **`UtxoSet` owner:** standalone shared object vs. field on `Pool`. Redemption spec (Ika withdrawal) consumes it — coordinate object layout with that spec to avoid a second migration.
6. **Min confirmations config:** const `6` vs. an AdminCap-settable `Pool.required_confirmations`. Solana hardcodes via feature flag; recommend a `Pool` field for operational flexibility on mainnet.
