# 05 — Policy Gate + Ika Approval (Sui)

Production-hardening spec for the redemption **signing policy gate** and its binding to
**Ika dWallet Taproot signing**. This module makes the Sui `ika_policy` a real,
fund-safe gate instead of a rubber stamp, mirroring the Solana
`policy.rs` + `approve_redemption_signing.rs` design while reconciling with the
Sui/Ika object model and the existing `packages/sdk-sui/src/ika.ts` PTB builders.

Status of inputs verified while writing this spec:
- Solana policy predicates: `contracts/programs/utxopia/src/utils/policy.rs:41-56`
- Solana approval CPI gate: `contracts/programs/utxopia/src/instructions/approve_redemption_signing.rs:94-201`
- Solana Ika CPI byte layout / PDA derivation: `contracts/programs/utxopia/src/cpi/ika.rs`
- Solana trustless miner-fee derivation: `contracts/programs/utxopia/src/instructions/complete_redemption.rs:404-417`
- Solana redemption state (pinned `btc_script`, `total_input_sats`, `service_fee`): `contracts/programs/utxopia/src/state/redemption_request.rs`
- Current Sui stub: `chains/sui/contracts/sources/ika_policy.move` (whole file)
- Current Sui redemption: `chains/sui/contracts/sources/redemption.move` (whole file)
- Current Sui Ika PTB builders: `packages/sdk-sui/src/ika.ts` (`buildApproveTaprootMessageTransaction`, `buildRequestGlobalTaprootPresignTransaction`, `buildTaprootSignWithPublicSharesTransaction`)
- Current SDK approval call: `packages/sdk-sui/src/sui-adapter.ts:207-235` (`buildIkaApprovalTransaction`)

---

## 1. Goal & what it replaces

### 1.1 The stub being replaced

`chains/sui/contracts/sources/ika_policy.move::approve_signing` currently does:

```move
public fun approve_signing(pool, queue, redemption_id, sighash) {
    pool::assert_not_paused(pool);
    assert!(redemption::is_pending(queue, redemption_id), errors::policy_rejected());
    assert!(vector::length(&sighash) == 32, errors::policy_rejected());
    events::ika_signing_approved(pool::pool_id(pool), redemption_id, sighash);
}
```

Three fatal gaps versus the Solana reference:

1. **No amount/fee policy.** Solana enforces `amount_sats <= MAX_REDEMPTION_AMOUNT_SATS (1 BTC)`
   and `miner_fee_sats <= MAX_MINER_FEE_SATS (50_000)` (`policy.rs:29-32,49-53`). The Sui
   stub does neither. A compromised relayer can request signing for an arbitrary amount.
2. **No binding of the approved `sighash` to the redemption's pinned destination.**
   The Solana `RedemptionRequest` pins `btc_script` (the destination scriptPubKey)
   at request time (`redemption_request.rs` `btc_script` field) and SPV-cross-checks
   the broadcast output against it in `complete_redemption.rs:392-402`. The Sui stub
   takes an opaque `sighash` from the caller and emits it with **zero** relationship to
   the redemption's `btc_address_hash`. Nothing stops the relayer from approving a
   sighash that spends to an attacker address.
3. **Approval is not recorded on-chain in a way Ika can consume.** It emits an event and
   returns. The Sui Ika model (`ika.ts`) builds the `approveMessage` PTB **off-chain**
   against `@ika.xyz/sdk`, so today the on-chain "approval" and the actual Ika signing
   are completely disjoint — the dWallet will sign *any* message the relayer hands it.

### 1.2 What this module must guarantee

> The Sui dWallet only ever produces a Taproot signature for a sighash that the
> on-chain policy gate has bound to a specific, still-pending redemption whose
> amount and (completion-time) miner fee are within policy, and whose destination
> equals the redemption's pinned `btc_script`.

Because Sui's Ika integration is a **PTB composed off-chain** (not an on-chain CPI like
Solana's `invoke_signed` into the Ika program), we cannot make the dWallet *technically
incapable* of signing an unapproved message the way Solana's `__ika_cpi_authority` PDA
does. Instead we achieve the equivalent guarantee with an **on-chain approval object +
a same-PTB composition rule** (Section 2.4 and Section 4.4). This is the one structural
divergence from Solana and is called out explicitly as an open question (Section 10).

---

## 2. Sui-native data model

### 2.1 Why Solana PDAs don't map 1:1

| Solana | Sui equivalent here | Note |
|---|---|---|
| `RedemptionRequest` PDA (per-request, program-owned) | entry in the shared `RedemptionQueue.requests` vector (object 06) | Sui has no per-request PDA; requests live in the shared queue. |
| `__ika_cpi_authority` PDA gating the Ika CPI | dWalletCap held by the protocol + `SigningApproval` object (below) | Sui Ika has no CPI-authority concept; the dWalletCap is the bearer authority. |
| `MessageApproval` PDA created by the Ika program | `IkaTransaction.approveMessage(...)` hot-potato value inside the signing PTB | Created and consumed in the *same* PTB off-chain. |
| `CompletionReceipt` PDA (dedup) | `completed: bool` on the queued request (already present) | Reused. |

### 2.2 New on-chain object: `SigningApproval`

We add a **policy-bound, single-use approval record** that the off-chain Ika signer must
read and match before composing the sign PTB. It is the Sui stand-in for Solana's
`MessageApproval` PDA, but owned by *our* package so the policy is enforced where we
control it.

```move
module utxopia::ika_policy {

    /// Single-use, policy-checked authorization to Taproot-sign exactly one sighash
    /// for exactly one redemption. Shared so the off-chain signer can read it by ID,
    /// but only `consume_approval` (gated by RedemptionCap) can flip `used`.
    public struct SigningApproval has key, store {
        id: UID,
        pool_id: address,            // binds to one pool instance
        redemption_id: u64,          // binds to one queued request
        btc_script: vector<u8>,      // pinned destination scriptPubKey (copied from request)
        amount_sats: u64,            // gross amount checked against MAX_REDEMPTION_AMOUNT_SATS
        sighash: vector<u8>,         // 32-byte BIP-341 key-spend sighash that Ika may sign
        dwallet_cap_id: address,     // the dWalletCap this approval is valid for
        epoch_created: u64,          // tx_context::epoch() — for expiry
        used: bool,                  // single-use guard; flipped on consume
    }
}
```

Object disposition: **shared** (`transfer::share_object`). It must be readable by the
off-chain signer (which does not hold any cap) and writable by the completion path.
Rationale for shared vs owned: an owned object addressed to the relayer would let the
relayer transfer/destroy it and is not readable by an independent watcher. Shared keeps
it auditable and indexable (the indexer in `chains/sui/indexer/src/*` keys off it).

### 2.3 Capabilities

- `RedemptionCap` (already defined in `redemption.move`) authorizes `approve_signing`
  and `consume_approval`. It is the protocol's "pool authority" equivalent of Solana's
  `authority` signer check (`approve_redemption_signing.rs:118-132`). **Locked decision
  reminder:** target is trustless mainnet parity — `RedemptionCap` must NOT be a single
  hot key that can drain funds. It gates *who can request signing*, but fund safety comes
  from the amount/fee/destination binding below, exactly as Solana's design where even the
  authority cannot exceed `MAX_REDEMPTION_AMOUNT_SATS`. See Section 7 risk R1.

- The **Ika dWalletCap** is held by the protocol operator (an owned object referenced in
  config: `UTXOpiaSuiIkaConfig.dWalletCapObjectId`). Whoever holds it can technically ask
  Ika to sign; the binding rule (2.4) is what constrains it. See R1.

### 2.4 The binding rule (replaces Solana's CPI-authority guarantee)

On Solana the Ika program checks `dwallet.authority == cpi_authority.key()` so only our
program can fire `approve_message`. On Sui there is no such hook. We enforce binding two
ways, defense in depth:

1. **On-chain, at completion (authoritative, trustless):**
   `redemption::complete_redemption` (object 06) already SPV-verifies the broadcast tx
   and will, per this spec, recompute `miner_fee = total_input_sats - sum(tx_outputs)`
   and assert the destination output pays `request.btc_script`. **Funds cannot be
   finalized (zkBTC not burned, request not marked completed) unless the broadcast tx
   matches policy.** This is the real safety net and is identical in spirit to
   `complete_redemption.rs:392-417`.

2. **Off-chain, at signing (operational, reduces blast radius):** the off-chain Ika
   signer (Section 4.4) MUST, before composing the `requestSign` PTB:
   - fetch the `SigningApproval` object by `(pool_id, redemption_id)`,
   - assert `used == false`, `epoch_created` not expired,
   - assert the message it is about to sign **byte-equals** `approval.sighash`,
   - assert `approval.dwallet_cap_id == configured dWalletCap`,
   - compose `consume_approval(cap, queue, approval, &mut tx)` **in the same PTB** as
     `IkaTransaction.requestSign(...)`, so the approval is burned atomically with signing.

The on-chain `consume_approval` is what flips `used = true`; if the signer omits it the
PTB is still valid Ika-wise but leaves a replayable approval — hence (1) remains the
authoritative guarantee. We document this honestly in R1/Open-Q1.

---

## 3. Function signatures

### 3.1 `ika_policy.move`

```move
/// Policy constants — must equal Solana policy.rs.
const MAX_REDEMPTION_AMOUNT_SATS: u64 = 100_000_000; // 1 BTC  (policy.rs:29)
const MAX_MINER_FEE_SATS: u64        = 50_000;       //        (policy.rs:32)
const SIGNING_APPROVAL_EXPIRY_EPOCHS: u64 = 1;       // approval valid for current+next epoch
const SIGHASH_LEN: u64 = 32;

/// Pure predicate port of policy.rs::check_redemption_signing.
/// Aborts with errors::policy_rejected()/pool_paused() on violation.
public fun check_redemption_signing(
    pool: &Pool,
    amount_sats: u64,
    miner_fee_sats: u64,
);

/// Create a single-use, policy-bound SigningApproval for one redemption.
/// Replaces the old approve_signing stub. Gated by RedemptionCap.
public fun approve_signing(
    _cap: &RedemptionCap,
    pool: &Pool,
    queue: &RedemptionQueue,
    dwallet_cap: &ID,                 // the dWalletCap object id this approval is valid for
    redemption_id: u64,
    estimated_miner_fee_sats: u64,    // upper-bound fee the relayer commits to at approval time
    sighash: vector<u8>,              // 32-byte BIP-341 key-spend sighash
    ctx: &mut TxContext,
);

/// Single-use consume: flips `used`, asserts it matches the request still-pending.
/// Called in the SAME PTB as IkaTransaction.requestSign by the off-chain signer.
/// Gated by RedemptionCap. Aborts if used, wrong pool, request completed, or expired.
public fun consume_approval(
    _cap: &RedemptionCap,
    pool: &Pool,
    queue: &RedemptionQueue,
    approval: &mut SigningApproval,
    ctx: &TxContext,
);

/// Read-only getters for the off-chain signer / indexer.
public fun approval_sighash(a: &SigningApproval): vector<u8>;
public fun approval_redemption_id(a: &SigningApproval): u64;
public fun approval_used(a: &SigningApproval): bool;
public fun approval_btc_script(a: &SigningApproval): vector<u8>;
```

### 3.2 `redemption.move` additions (depends-on-06 contract surface)

This module **depends on `redemption.move`** (object 06). The policy gate needs three
fields that the current `RedemptionRequest` lacks. They are owned by spec 06 but listed
here as the required interface:

```move
// Required on RedemptionRequest (added by 06):
//   btc_script: vector<u8>      // raw destination scriptPubKey (NOT bech32). pins destination.
//   service_fee_sats: u64       // locked at request time from pool config
//   total_input_sats: u64       // set at mark_processing from on-chain UTXO objects
//   status: u8                  // Pending=0 / Processing=1 / Completed.. (replaces bare `completed`)

// Required accessors (public(package)) consumed by ika_policy:
public(package) fun request_btc_script(queue: &RedemptionQueue, id: u64): vector<u8>;
public(package) fun request_amount_sats(queue: &RedemptionQueue, id: u64): u64;
public(package) fun request_is_pending(queue: &RedemptionQueue, id: u64): bool;
public(package) fun request_total_input_sats(queue: &RedemptionQueue, id: u64): u64;
```

> Migration note: the current `request_redemption` takes `btc_address_hash` (a hash) and
> `max_fee_sats`. For destination binding we need the **raw scriptPubKey**, not a hash,
> because completion must byte-compare the broadcast output's `script_pubkey`
> (`complete_redemption.rs:392`). Spec 06 must change `btc_address_hash -> btc_script`.
> This is a breaking SDK change tracked in `sui-adapter.ts:194`.

---

## 4. Algorithm (step by step)

### 4.1 `check_redemption_signing` (port of `policy.rs:41-56`)

```
1. if pool::paused(pool)                      -> abort pool_paused()      // policy.rs:46
2. if amount_sats > MAX_REDEMPTION_AMOUNT_SATS -> abort policy_rejected() // policy.rs:49
3. if miner_fee_sats > MAX_MINER_FEE_SATS      -> abort policy_rejected() // policy.rs:52
4. return
```

No integer arithmetic, so no overflow surface. Constants are compile-time `const` so they
cannot drift without redeploy (matches the Solana "bumps require redeploy" comment,
`policy.rs:28`).

### 4.2 `approve_signing` (port of `approve_redemption_signing.rs:94-201`)

```
1. assert vector::length(&sighash) == SIGHASH_LEN              (approve_redemption_signing.rs:53 analog)
2. assert redemption::request_is_pending(queue, redemption_id) (==1136-138: status must be Processing/Pending)
3. amount  := redemption::request_amount_sats(queue, redemption_id)
   script  := redemption::request_btc_script(queue, redemption_id)
   tinput  := redemption::request_total_input_sats(queue, redemption_id)
4. assert tinput > 0                                            (mirror :139-141 InvalidUtxo)
5. check_redemption_signing(pool, amount, estimated_miner_fee_sats)   // policy gate, pre-sign
6. construct SigningApproval {
       pool_id = pool::pool_id(pool),
       redemption_id, btc_script = script, amount_sats = amount,
       sighash, dwallet_cap_id = *dwallet_cap,
       epoch_created = tx_context::epoch(ctx), used = false,
   }
7. emit IkaSigningApproved(pool_id, redemption_id, sighash)     // keep existing event
8. transfer::share_object(approval)
```

Notes:
- Step 5 uses the relayer-committed `estimated_miner_fee_sats` as the pre-sign bound.
  The Solana code uses `ix_data.miner_fee_sats` the same way (`approve_redemption_signing.rs:143`)
  — at approval time the broadcast tx doesn't exist yet, so the fee is an asserted upper
  bound. The **authoritative** fee check happens at completion (4.5) against the real tx.
- We do NOT compute/echo an `ika_message_digest` keccak (Solana `approve_redemption_signing.rs:164-166`)
  because on Sui the digest handling lives inside `@ika.xyz/sdk`'s `approveMessage` —
  `ika.ts:buildApproveTaprootMessageTransaction` passes the 32-byte `message` directly with
  `Hash.SHA256`. The `sighash` we store **is** the message. See Section 5.2.

### 4.3 `consume_approval`

```
1. assert approval.used == false                               -> abort policy_rejected()
2. assert approval.pool_id == pool::pool_id(pool)              -> abort policy_rejected()
3. assert redemption::request_is_pending(queue, approval.redemption_id)
4. assert tx_context::epoch(ctx) <= approval.epoch_created + SIGNING_APPROVAL_EXPIRY_EPOCHS
5. approval.used = true
```

### 4.4 Off-chain Ika signing reconciliation (PTB composition)

The signer flow ties `approve_signing` (on-chain) -> Ika presign -> Ika sign together. It
maps onto the existing `ika.ts` builders. The dWallet must be a `shared` or
`imported-key-shared` kind so signing needs no per-user encrypted share
(`ika.ts:160-188` handles `zero-trust`/`shared`/`imported-key-shared`).

```
A. (one-time) request a global Taproot presign:
     ika.ts::buildRequestGlobalTaprootPresignTransaction(...)
   -> yields a presignId usable for any later sign.

B. relayer builds unsigned BTC tx (inputs = pool UTXOs, output[0] = request.btc_script
   for amount-service_fee, output[1] = change to pool script), computes the BIP-341
   key-spend sighash `S` (Section 5.1).

C. on-chain approval:
     adapter.buildIkaApprovalTransaction({ redemptionId, sighash: S, estimatedMinerFee })
   -> calls ika_policy::approve_signing -> creates SigningApproval object, id = APP.

D. off-chain signer guard (Section 2.4): fetch APP, assert used==false, not expired,
   APP.sighash == S, APP.dwallet_cap_id == config.dWalletCapObjectId.

E. single PTB combining consume + sign:
     tx.moveCall(ika_policy::consume_approval, [cap, pool, queue, APP])   // flips used
     messageApproval = ikaTx.approveMessage({ dWalletCap, curve SECP256K1,
                          signatureAlgorithm Taproot, hashScheme SHA256, message: S })
     verifiedPresignCap = ikaTx.verifyPresignCap({ presign })
     ikaTx.requestSign({ dWallet, messageApproval, verifiedPresignCap, presign,
                          message: S, signatureScheme Taproot, ikaCoin, suiCoin })
   (extends ika.ts::buildTaprootSignWithPublicSharesTransaction to also include the
    consume_approval moveCall in the same Transaction.)

F. poll Ika for the produced Schnorr signature; assemble Taproot key-spend witness;
   broadcast BTC tx.

G. on-chain finalize: redemption::complete_redemption (06) SPV-verifies the broadcast,
   recomputes miner fee, asserts destination == request.btc_script, burns zkBTC, marks
   request completed.
```

### 4.5 Trustless miner-fee computation on Sui (the key reconciliation)

> "Define how miner_fee is computed trustlessly on Sui."

Mirror Solana exactly (`complete_redemption.rs:404-417`). The fee is **derived, never
trusted**, at completion from SPV-verified data:

```
miner_fee = total_input_sats  -  sum(tx_outputs)
```

- `total_input_sats` is set on the `RedemptionRequest` at `mark_processing` time by
  summing the **on-chain UTXO objects** the protocol reserves (Solana: `mark_processing.rs:85-132`;
  Sui equivalent lives in object 06's UTXO tracking). It is on-chain data, not relayer
  input. Spec 06 owns the UTXO objects; this module only *reads* `total_input_sats`.
- `sum(tx_outputs)` is computed by parsing the SPV-verified raw BTC tx. The tx bytes come
  from the BTC light client's verified-transaction path (object 02 — `btc_light_client.move`),
  and output parsing reuses the same scriptPubKey/value parser that
  `btc_deposit.move` will use for deposits (the deposit path already pulls outputs in
  `btc_deposit.move`). Implement a shared `bitcoin::parse_tx_outputs(raw) -> vector<Output{value:u64, script:vector<u8>}>` helper if not present.
- The pre-sign `estimated_miner_fee_sats` in `approve_signing` (4.2 step 5) is an upper
  bound for early rejection only. Completion's derived `miner_fee` is authoritative and is
  re-checked with `check_redemption_signing(pool, amount, miner_fee)` exactly as
  `complete_redemption.rs:425`.

Edge: `total_input_sats == 0` aborts (`complete_redemption.rs:407`, `AmountTooSmall`). Use
`saturating_sub` semantics — but on Sui native u64 subtraction aborts on underflow, so
compute `if total_input_sats < total_outputs { abort policy_rejected() } else { total_input_sats - total_outputs }`
to avoid an unintended abort being mistaken for an overpay (R4).

---

## 5. Crypto primitives & exact parameters

This module does **not** do Poseidon or Merkle work — those belong to the merkle/transact
specs. The crypto surface here is the **Bitcoin Taproot signing message** and the Ika
signature scheme tag.

### 5.1 BIP-341 key-spend sighash (the message Ika signs)

- Algorithm: BIP-341 / BIP-342 key-path spend sighash. `SIGHASH_DEFAULT (0x00)` is assumed
  (whole-tx commitment, no annex). Single 32-byte tagged hash (tag `"TapSighash"`),
  computed by the relayer off-chain when it builds the unsigned tx (Section 4.4 B).
- It is 32 bytes (`SIGHASH_LEN`). `approve_signing` asserts the length (4.2 step 1) but
  does **not** recompute it on-chain — same decision as Solana
  (`policy.rs:13-14` "sighash recomputation: too expensive on-chain; sighash arrives
  opaque"). Trust is restored at completion via SPV (4.5).

### 5.2 Ika signature scheme parameters (mapping Solana scheme tags -> Sui SDK enums)

| Concept | Solana (`cpi/ika.rs`) | Sui (`@ika.xyz/sdk` via `ika.ts`) |
|---|---|---|
| curve | implicit secp256k1 (`CURVE_SECP256K1_LE`) | `Curve.SECP256K1` |
| scheme | `SIG_SCHEME_TAPROOT_SHA256 = 3` | `SignatureAlgorithm.Taproot` |
| hash | SHA-256 | `Hash.SHA256` |
| message | 32-byte sighash passed as `message_digest` | 32-byte `message: Uint8Array` |

Critical parameter parity assertions (encode as TS unit tests, Section 9):
- `ika.ts` MUST use `Curve.SECP256K1` + `SignatureAlgorithm.Taproot` + `Hash.SHA256`
  everywhere a redemption is signed. It already does (`ika.ts:74-80,138-145,166-189`).
- The `message` handed to `approveMessage`/`requestSign` MUST byte-equal
  `SigningApproval.sighash`. The off-chain guard (4.4 D) enforces this; a test must assert it.

### 5.3 Field-element canonicalization

Not applicable to this module — no `poseidon_bn254` inputs are produced here. (The note in
the task about field-element canonicalization applies to the merkle/commitment specs.) The
only "32-byte" values here are the sighash (an opaque hash, no field reduction) and the
dWalletCap/object ids (Sui `address`/`ID`, already canonical).

---

## 6. Gas / performance

- `approve_signing` creates one shared object: dominant cost is object creation +
  storage rebate accounting. `btc_script` is <= 34 bytes, `sighash` 32 bytes — tiny.
- `consume_approval` is a single bool flip + a linear scan of `RedemptionQueue.requests`
  (current `borrow_request` is O(n), `redemption.move:84-96`). For mainnet this scan
  should become a `Table<u64, RedemptionRequest>` keyed by `redemption_id` (R6) — flagged
  as a 06 dependency, but the policy gate's `request_is_pending` lookup inherits the same
  O(n). Until then, queue length is bounded by completed-request pruning.
- No pairing/hashing in this module, so it is far below Sui's per-PTB budget. The Ika
  presign/sign PTBs (`ika.ts`) are the expensive part and are unchanged by this spec.
- Mitigation: keep `SigningApproval` minimal (no vectors beyond the two 32/34-byte ones);
  do not store the full unsigned tx on-chain (the relayer holds it; SPV re-derives at
  completion).

---

## 7. Risks, edge cases, security pitfalls

- **R1 — dWalletCap is bearer authority (the core divergence).** On Sui, whoever holds the
  dWalletCap can compose an Ika sign PTB *without* calling `consume_approval`, signing an
  arbitrary message. We cannot prevent this at the Move layer the way Solana's
  `__ika_cpi_authority` PDA does. Mitigations: (a) completion-time SPV gate is the
  authoritative fund-safety check — an off-policy signature can be produced but **cannot
  be finalized into a burn**, and the BTC it tries to move must come from pool UTXOs whose
  spend the protocol's tx-builder controls; (b) operationally hold the dWalletCap in an
  HSM/MPC-guarded signer that refuses to sign without a matching unused `SigningApproval`;
  (c) consider an Ika `imported-key-shared`/policy-restricted dWallet if Ika exposes an
  on-chain approval-required mode (Open-Q1). Document as accepted residual risk for v1.
- **R2 — Replay of `SigningApproval`.** `used` + epoch expiry + completion marking the
  request `Completed` (so `request_is_pending` is false) close the replay window. A
  signature already produced for sighash S can be re-broadcast, but BTC's own UTXO model
  prevents double-spend of the same inputs, and completion dedup (`completed` flag,
  `redemption.move:69-70`) prevents double-finalize.
- **R3 — Destination substitution.** Prevented by pinning `btc_script` in the request and
  byte-comparing the SPV output at completion (`complete_redemption.rs:392-402`). This is
  why `request_redemption` must store the raw scriptPubKey, not a hash (Section 3.2 note).
- **R4 — Underflow / overpay accounting.** If the relayer overpays the user
  (`total_outputs > total_input_sats`) native u64 subtraction aborts. Use the explicit
  `if total_input_sats < total_outputs` guard (4.5) so an overpay is a clean policy reject,
  not a confusing arithmetic abort. Solana uses `saturating_sub` (`complete_redemption.rs:411`)
  then bounds `miner_fee > MAX_FEE_SATS`.
- **R5 — Tx malleability.** Taproot key-spend sighash commits to all inputs/outputs, so the
  signed witness is not malleable in a way that changes the txid's meaning for our checks.
  The light client must verify the *witness txid* delivery (object 02 concern). Approval is
  bound to the sighash, which already commits to outputs.
- **R6 — O(n) queue scan** (perf, see Section 6) becomes a soft-DoS as the queue grows.
  Fix via `Table` in 06.
- **R7 — Paused mid-flight.** `pool::paused` is checked in `approve_signing` (4.1) and again
  at completion (`check_redemption_signing`). A redemption approved just before pause can
  still be signed off-chain, but completion will abort while paused — funds stay safe. This
  matches Solana (paused checked in both `approve_redemption_signing.rs` via policy and
  `complete_redemption.rs:425`).
- **R8 — Epoch expiry too tight.** Sui epochs are ~24h. `SIGNING_APPROVAL_EXPIRY_EPOCHS=1`
  gives the relayer up to ~2 epochs to presign/sign/broadcast/confirm 6 BTC blocks (~60min)
  — comfortable, but make it config so mainnet can widen it.
- **R9 — Wrong dWalletCap.** `approval.dwallet_cap_id` binds the approval to one cap; the
  off-chain guard (4.4 D) rejects a mismatch so a stale approval from a rotated dWallet is
  unusable.

---

## 8. Dependencies on other modules in this design set

- **06 — redemption** (hard dependency): provides `RedemptionRequest` with
  `btc_script`/`service_fee_sats`/`total_input_sats`/`status`, the `RedemptionCap`,
  `mark_processing` (sets `total_input_sats` from on-chain UTXO objects), and the
  `complete_redemption` SPV gate that recomputes the authoritative miner fee (4.5). This
  module is meaningless without 06's destination pinning and fee derivation.
- **02 — btc_light_client** (indirect): supplies the SPV-verified raw redemption tx and
  output parsing used by 06's completion to derive `sum(tx_outputs)` and match `btc_script`.
- **pool** (existing): `paused` flag + `pool_id`. Reused unchanged.
- **events** (existing): `IkaSigningApproved` reused; optionally add `IkaApprovalConsumed`.
- **Off-chain `packages/sdk-sui/src/ika.ts`** (existing): unchanged signing scheme, but
  `buildTaprootSignWithPublicSharesTransaction` must be extended to inject the
  `consume_approval` moveCall and the off-chain approval guard (4.4 D/E).
- **`packages/sdk-sui/src/sui-adapter.ts:207-235`**: `buildIkaApprovalTransaction` signature
  changes to pass `RedemptionCap`, the dWalletCap id, and `estimatedMinerFeeSats`, and to
  return/track the created `SigningApproval` object id.

---

## 9. Test matrix

### Move unit tests (`#[test]` in `ika_policy.move`)
1. `check_redemption_signing` accepts amount==MAX and fee==MAX (port `policy.rs:69-79`).
2. rejects amount==MAX+1 (port `policy.rs:81-88`).
3. rejects fee==MAX+1 (port `policy.rs:90-96`).
4. rejects when pool paused (port `policy.rs:98-108`).
5. `approve_signing` happy path: creates `SigningApproval` with correct
   `redemption_id/btc_script/amount/sighash/used=false` and emits `IkaSigningApproved`.
6. `approve_signing` aborts on sighash length != 32.
7. `approve_signing` aborts when request not pending (status==Completed).
8. `approve_signing` aborts when `total_input_sats == 0`.
9. `approve_signing` aborts when `estimated_miner_fee > MAX_MINER_FEE_SATS`.
10. `approve_signing` aborts when `amount > MAX_REDEMPTION_AMOUNT_SATS`.
11. `consume_approval` flips `used`; second call aborts (single-use).
12. `consume_approval` aborts on wrong `pool_id`.
13. `consume_approval` aborts when epoch > created + EXPIRY.
14. `consume_approval` aborts when request already completed.
15. Miner-fee derivation helper: `total_input=100k, outputs=80k -> fee=20k` accepted;
    `outputs=120k (overpay)` -> clean policy reject (no arithmetic abort, R4);
    `total_input=100k, outputs=40k -> fee=60k > MAX` -> reject.

### TS / integration tests
16. `sui-adapter.buildIkaApprovalTransaction` produces a PTB targeting
    `ika_policy::approve_signing` with the new arg list and 32-byte sighash.
17. Off-chain guard: signer refuses to compose `requestSign` when the on-chain
    `SigningApproval.sighash` != message it intends to sign.
18. Parameter parity: the message handed to `ikaTx.approveMessage`/`requestSign` byte-equals
    `SigningApproval.sighash`; scheme is `Taproot`, curve `SECP256K1`, hash `SHA256`.
19. Same-PTB composition: `consume_approval` and `requestSign` appear in one Transaction;
    after execution `approval_used()==true`.
20. End-to-end (extend `chains/sui/scripts/regtest-flow.ts`): request -> mark_processing
    (sets total_input) -> approve_signing -> Ika presign+sign -> broadcast on regtest ->
    complete_redemption asserts destination==btc_script and derived fee within MAX; burn
    succeeds. Negative: tamper the broadcast output address -> completion aborts, no burn.
21. Pause mid-flight (R7): approve while unpaused, pause, attempt complete -> abort.

---

## 10. Effort estimate & open questions

**Effort: 4-6 developer-days.**
- ~1.5d Move: `SigningApproval` object, `check_redemption_signing`, `approve_signing`,
  `consume_approval`, getters, accessors coordination with 06.
- ~1d Move tests (15 unit cases).
- ~1d TS: `ika.ts` extension (inject `consume_approval`, off-chain guard) +
  `sui-adapter.buildIkaApprovalTransaction` signature change.
- ~1d integration wiring into `regtest-flow.ts` incl. the trustless-fee completion path
  (shared with 06).
- ~0.5-1.5d buffer for the dWalletCap/binding reconciliation and Ika SDK behavior
  discovery (Open-Q1) — this is the riskiest unknown.

**Open questions:**
1. **(Highest)** Does `@ika.xyz/sdk` / the Ika Move package expose an on-chain
   "approval-required before sign" mode (so the dWalletCap alone can't sign)? If yes, we can
   replace the off-chain guard with a true on-chain binding equivalent to Solana's
   `__ika_cpi_authority`, eliminating R1's residual risk. If no, R1 stays an accepted
   operational risk for v1 and the completion-time SPV gate is the sole trustless guarantee.
2. Should `SigningApproval` be deleted (storage rebate) on `consume_approval`, or kept as an
   immutable audit record for the indexer? Leaning: keep `used=true` shared for auditability;
   prune in a later sweep.
3. Confirm the exact BIP-341 sighash flavor the Ika Taproot path expects
   (`SIGHASH_DEFAULT` vs `SIGHASH_ALL`), and whether Ika applies the `TapSighash` tag
   itself or expects the already-tagged 32 bytes as `message`. Determines whether the
   relayer's sighash and the on-chain stored sighash are pre- or post-tag.
4. Should `RedemptionCap` be split into a low-privilege `ApproveCap` (can call
   `approve_signing`) vs an admin cap, to follow least-privilege for mainnet?
5. Confirm 06 will migrate `RedemptionQueue` to a `Table` (R6) so policy-gate lookups are
   O(1); otherwise document the O(n) bound and a max queue depth.
