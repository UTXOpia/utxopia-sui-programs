# 00 — UTXOpia Sui: Production Hardening Master Build Plan

Status: planning, implementation-ready
Target: **trustless mainnet parity** with the Solana implementation (no trusted relayer for fund safety).
Scope: turn the Sui PoC (`chains/sui/`) into a fund-safe, mainnet-grade port of the Solana bridge.

This is the umbrella document for the seven per-module specs. Read the per-module spec before
implementing each module — this file gives sequencing, the cross-cutting risk register, milestones,
and the human decisions that gate the work.

Per-module specs (relative links):
- [01 — Bitcoin SPV Light Client (Move)](./01-spv-light-client.md)
- [02 — SPV TX Inclusion + Bitcoin TX Parser (Move)](./02-spv-inclusion-and-tx-parser.md)
- [03 — On-Chain Poseidon Commitment Merkle Tree (Move)](./03-poseidon-merkle-tree.md)
- [04 — Complete-Deposit Wiring (Move)](./04-complete-deposit-wiring.md)
- [05 — Policy Gate + Ika Approval (Move + TS)](./05-policy-gate-and-ika-approval.md)
- [06 — Sui Indexer: Persistence, Sync, Note Scanning (TS)](./06-indexer-persistence-and-notes.md)
- [07 — Sui SDK: Submission, State, >2×2 Splitter (TS)](./07-sdk-submission-and-state.md)

---

## 1. Executive Summary — PoC → Trustless Mainnet Parity

The Sui PoC works end-to-end only because **two load-bearing pieces are fake**:

1. **`btc_light_client.move::new_verified_deposit` (lines 16–40) does ZERO verification** — it only
   length-checks fields. Anyone who can construct a `VerifiedBtcDeposit` mints an arbitrary BTC
   deposit and steals funds. This is an open critical hole today.
2. **`merkle.move` is a SHA256 hash-chain, not a Merkle tree** (`merkle.move:27`,
   `sha2_256(prev_root || commitment)`). The on-chain "root" has no relationship to the circom
   circuit root, so no deposit could ever actually be spent via a real Groth16 proof.

A third gap makes redemptions unsafe: **`ika_policy::approve_signing` is a rubber stamp** — no
amount/fee policy and no binding of the signed sighash to the redemption's pinned destination.

The path to parity is therefore: **build the real crypto/SPV spine** (Poseidon tree + SPV light
client + inclusion/parser), **wire trustless deposit completion on top of it**, **harden the
redemption policy gate + Ika approval**, and **productionize the off-chain plane** (durable indexer +
signer-capable SDK). The result mirrors the Solana programs file-for-file in behavior, with the on-
chain Poseidon tree producing roots **bit-identical** to the circuit, Solana, and the SDK.

One **accepted divergence** from Solana is baked into the design and is not a defect — see §4.

The estimated total is **36–51 developer-days** of focused work across the seven modules (plus the
small Move `StealthAnnounced` event that unblocks transfer scanning).

---

## 2. Dependency-Ordered Build Sequence

```
        ┌─────────────────────── FOUNDATIONAL CRYPTO/SPV SPINE ───────────────────────┐
        │                                                                              │
   03 Poseidon Merkle Tree        01 SPV Light Client                                  │
   (real depth-16 tree)           (header chain / PoW / retarget / chainwork reorg)    │
        │                                  │                                           │
        │                                  ▼                                           │
        │                          02 SPV Inclusion + TX Parser                        │
        │                          (Merkle inclusion + OP_RETURN parse,                │
        │                           consumes 01's block accessors)                     │
        │                                  │                                           │
        └──────────────┬───────────────────┘                                          │
                       ▼                                                               │
              04 Complete-Deposit Wiring  ◄── depends on 01 + 02 + 03                  │
              (SPV deposit → fee → Poseidon commitment → tree insert → dedup)          │
                       │                                                               │
        ┌──────────────┴───────────────────────────────────────────────┐             │
        ▼                                                               ▼             │
  06 Indexer (TS)                                              05 Policy + Ika (semi-  │
  (durable persistence, sync, note scan)                       independent: needs     │
        │  ▲ needs Move StealthAnnounced event                  redemption 06-move +   │
        │  │ (small transact/events change)                     pool/events; off-chain │
        ▼  │                                                    Ika SDK reconciliation)│
  07 SDK (TS)  ◄── consumes 06 indexer API; reuses 03/04 commitment+root semantics ───┘
  (signer submission, state reads, >2×2 splitter)
```

### Strict ordering rules

1. **`poseidon_bn254` parity gate runs FIRST, before any other code.** Tests U1/U2 in Spec 03 and
   the §9.1 vectors in Spec 04 (`Poseidon([1,2]) == 0x115cc0f5…189a`, `Poseidon([1,2,3]) ==
   0x0e7732…d732`, full zero-ladder recompute to `ZERO[16] == 0x2a7c…7323`) must pass on a real Sui
   target. If Sui's native Poseidon is not circomlibjs-identical, the entire deposit/transact/tree
   design is invalid and must be re-planned (Move-level Poseidon = expensive). **No module that
   depends on Poseidon should start until this is green.**

2. **Module 03 (Poseidon tree)** and **Module 01 (SPV light client)** are independent of each other
   and are both foundational — build in parallel.

3. **Module 02 (inclusion + parser)** depends on Module 01's read accessors
   (`block_merkle_root`, `block_height`, `has_block`, `tip_height`). Start after 01's accessor
   surface is stable (can begin against stubbed accessors).

4. **Module 04 (complete-deposit)** depends on **all three** of 01, 02, 03. It is the integration
   point: consumes 02's `VerifiedTxInclusion` hot potato, computes the commitment, inserts into 03's
   tree, reads 01's tip for confirmations. It cannot finish until 01/02/03 land, though its
   `utxopia::bitcoin` tx-parser sub-library (shared with 02) can be built early.

5. **Module 06 (indexer)** and **Module 07 (SDK)** can proceed in parallel with the Move work, but:
   - 06 has a **hard Move blocker**: a new `StealthAnnounced` event emitted by `transact` (Spec 06
     §2.5). Without it, transfer notes are unscannable. This is a small change to `transact.move` /
     `events.move` and should be scheduled into the Move sprint early.
   - 07 consumes 06's HTTP API and reuses 03/04 commitment+root semantics; its **submission
     lifecycle and signer abstraction** have no Move dependency and can start immediately. Its
     `getNotes`/state wiring and the `splitTransfer` planner firm up once 06's API and the
     commitment/root semantics are pinned.

6. **Module 05 (policy + Ika)** is **semi-independent**. It depends on a redemption Move module
   (referred to as "06-move" inside Spec 05 — the on-chain `redemption.move`, distinct from the TS
   indexer Spec 06) for `btc_script`/`total_input_sats`/`status` fields and the completion SPV gate,
   plus `pool`/`events`. It does NOT depend on the deposit spine (03/04) and can be built in parallel
   once the redemption Move surface is agreed. Its completion-time fee/destination check reuses the
   shared `bitcoin` output parser from 02/04.

### Recommended start order

1. **Day 0:** Poseidon parity vectors (Spec 03 U1/U2 + Spec 04 §9.1) — gate everything.
2. **Parallel track A (Move spine):** 03 Poseidon tree ∥ 01 SPV light client → 02 inclusion/parser →
   04 complete-deposit. Land the small `StealthAnnounced` event change inside this track early.
3. **Parallel track B (off-chain):** 07 SDK submission/signer (no deps) starts immediately; 06
   indexer schema/sync starts immediately. Both firm up note/state wiring after track A pins
   commitment/root semantics.
4. **Parallel track C (redemption):** redemption Move surface + 05 policy/Ika, gated only on
   `pool`/`events`/`redemption.move` and the shared `bitcoin` output parser.

---

## 3. Critical Path & Parallelization

**Critical path (longest serial chain to a trustless deposit→spend):**

```
poseidon parity gate → (01 SPV light client ∥ 03 Poseidon tree) → 02 SPV inclusion/parser
  → 04 complete-deposit → E2E deposit→transact reconciliation
```

This chain is what closes the two critical holes (forgeable deposit, fake tree) and proves a deposit
commitment lands in a real tree the circuit can prove against. Everything fund-safety-critical is on
this path.

**Parallelizable off the critical path:**

- **06 indexer** (entire TS service) — only the `StealthAnnounced` Move event touches the critical
  track, and that is a ~0.5d change schedulable independently.
- **07 SDK submission lifecycle + signer abstraction** — zero Move dependency; build immediately.
  The `splitTransfer` planner is pure/deterministic and testable with no chain.
- **05 policy + Ika + redemption Move** — independent of the deposit spine; depends only on
  `pool`/`events`/`redemption.move` and the shared `bitcoin` output parser (also used by 02/04, so
  build that parser once, early).
- **`utxopia::bitcoin` tx-parser library** — shared by 02, 04, and 05's completion fee check. Build
  it once at the front of the Move work; it unblocks three modules.

**Convergence points (where parallel tracks must sync):**

- 04 needs 01+02+03 done.
- 06 transfer-scanning needs the Move `StealthAnnounced` event.
- 07 `getNotes`/state needs 06's API; 07 splitter carry-note hashing needs 03/04 commitment semantics.
- M5 E2E needs all of the above.

---

## 4. Accepted Divergence From Solana (Design Decision, NOT a Defect)

> **Sui's native `groth16::verify_groth16_proof` hard-caps at 8 public inputs and exposes no raw
> BN254 pairing primitive.** Therefore the JoinSplit circuit catalog on Sui is **capped at
> 1×1 / 1×2 / 2×1 / 2×2** (`SUI_GROTH16_MAX_PUBLIC_INPUTS = 8`, `sdk-core/src/sui-circuits.ts`).
> Solana supports the full `JoinSplit(N,M)` catalog up to N+M ≤ 14; Sui cannot.

This is the **one accepted divergence** and is handled by **client-side transfer splitting** in the
SDK (Spec 07 §4.3): any logical transfer whose arity exceeds 2×2 is decomposed by `splitTransfer()`
into an ordered chain of ≤2×2 transacts using value-conserving **carry notes** (self-addressed
intermediate commitments). Each step:
- satisfies `sum(inputs) == sum(outputs)` (value conservation the circuit enforces),
- waits for the prior step's commitment to land and a fresh Merkle root to be observed before proving
  the next step (inter-step ordering),
- preserves public-input ordering `[merkleRoot, boundParamsHash, nullifiers…, commitmentsOut…]`.

Consequences accepted by all downstream modules:
- The on-chain Poseidon tree's worst-case per-tx load is **2 leaves = 32 Poseidon hashes** (a 2×2),
  which bounds gas (Spec 03 §6.2).
- The SDK adds a configurable step-count cap (default 8) and resumes partial plans from the last
  finalized carry note rather than restarting (Spec 07 §7.9).

Treat this as a fixed constraint. Do not attempt to lift the 8-input cap or hand-roll BN254 pairing.

---

## 5. Consolidated Risk Register (deduped across all specs)

Severity: **C**ritical / **H**igh / **M**edium / **L**ow.

### A. Crypto / interop parity

| ID | Sev | Risk | Source specs | Mitigation |
|----|-----|------|--------------|------------|
| **A1** | C | `sui::poseidon::poseidon_bn254` may not match circomlibjs BN254x5 (round constants / domain tag). If so, every commitment, tree node, and zero-ladder value diverges from the circuit → all deposits unspendable. | 03, 04 | **Run parity vectors FIRST** (Poseidon([1,2]), Poseidon([1,2,3]), full zero-ladder recompute to ZERO[16]). Gate all Poseidon-dependent work. CI canary on Sui framework bumps. |
| **A2** | H | Zero-ladder or node-hash-order mismatch silently produces a wrong-but-valid-looking root → deposits silently unspendable (no error). | 03 | Recompute ladder at build time (U2); assert `hash_node(1,2)` vector (U1); cross-check root vs SDK + circuit (X1–X3). |
| **A3** | H | Non-canonical field elements (input ≥ BN254 r). Solana *reduces* (`crypto.rs reduce_to_field` top-nibble mask); we must **REJECT**, never reduce — reducing aliases two byte strings to one commitment (double-mint) and desyncs from the circuit. | 03, 04, 07 | Hard `assert!(v < r)` on every field input (`field_from_be32`). SDK validates `< r` client-side before building. Do NOT port the Solana mask. |
| **A4** | M | u256 / byte-order endianness traps: BN254 big-endian field bytes vs Bitcoin little-endian targets/hashes vs internal-order txids. Most likely bug class. | 01, 02, 03, 04 | Centralize all conversions in named helpers; unit-test each; BE for field/commitment, LE for the stealth-announcement amount. |

### B. Bitcoin SPV / light client

| ID | Sev | Risk | Source specs | Mitigation |
|----|-----|------|--------------|------------|
| **B1** | C | `new_verified_deposit` mints deposits with no proof (lines 16–40). Open critical hole until 01+02 ship. | 01, 02, 04 | Delete/seal the stub; route all deposits through `verify_tx_inclusion` → hot-potato `VerifiedTxInclusion` (no abilities, in-PTB consume only). Reviewers confirm no residual public constructor (Spec 04 §7.2). |
| **B2** | H | Reorg height-index staleness: a shorter-but-heavier fork (across a retarget) leaves stale canonical hashes at upper heights, so orphaned blocks pass canonical checks. | 01 | After re-pointing, invalidate height entries `(new_tip+1 ..= old_tip)`; `verify_tx_inclusion` re-checks `canonical_hash_at(height) == block_hash` (stronger than Solana). Test I5/R3. |
| **B3** | H | Segwit malleability: hashing witness-serialized bytes yields wtxid (not in the tx-merkle tree) → root mismatch (liveness bug). | 02 | Require relayer to submit **legacy-serialized** tx bytes; parser tolerates but does not require the marker. Test legacy-vs-witness. |
| **B4** | M | u32 timestamp `wrapping_sub` in retarget underflows and ABORTS in Move (Rust wraps). | 01 | Hand-implement wrapping subtract to byte-match Rust; the `[ts/4, ts*4]` clamp tames the result. Test ts < epoch_start. |
| **B5** | M | Retarget off-by-one parity: must match Solana's apply-at-boundary semantics exactly, not Bitcoin Core's apply-to-next, or `expected_bits` diverges cross-chain. | 01 | Match Solana exactly (apply at `height % 2016 == 0`); test against real mainnet epoch headers (I7). |
| **B6** | M | Confirmation double-counting if Module 01 exposes a `finalized_height` that already bakes the 6-conf buffer; 02/04 would subtract twice. | 01, 02, 04 | Lock that 01 exposes raw `tip_height`; 02/04 do the confirmation math once. |
| **B7** | M | Merkle malleability (CVE-2012-2459 dup-node, 64-byte interior-node confusion) inherited from 01's stored root. | 01, 02 | Mitigated because 02/04 bind `txid == dsha256(raw_tx)` of a real parseable tx; a 64-byte interior node can't masquerade as the leaf. 01 must reject malformed-merkle headers. |
| **B8** | M | Parser DoS: unbounded inputs/outputs/proof-depth/tx-size cause gas griefing or aborts. | 02, 04 | Hard caps `MAX_INPUTS/MAX_OUTPUTS/MAX_PROOF_DEPTH/MAX_TX_BYTES`; explicit pre-read bounds checks (`E_TX_TRUNCATED`). |
| **B9** | M | Reorg after deposit credit: confirmations checked at tip at call time; a deeper reorg orphans a credited block. | 04 | Accepted, matches Solana; mitigated by `REQUIRED_CONFIRMATIONS = 6`. Out of threat scope beyond 6. |
| **B10** | L | Unbounded dynamic-field storage growth for headers/forks. | 01 | Prune watermark below finalized depth (permissionless `prune_below`, retention 1008–2016). |
| **B11** | L | Genesis checkpoint chainwork is admin-supplied and unverifiable on-chain (single trust root). | 01 | Publish checkpoint hash/height/work in deploy docs; gate `initialize` behind `AdminCap`. Same trust model as Solana. |

### C. Deposit / dedup / linkage

| ID | Sev | Risk | Source specs | Mitigation |
|----|-----|------|--------------|------------|
| **C1** | C | Forged `VerifiedBtcDeposit`: Spec 02 must be the ONLY constructor; object destruction alone is not idempotency. | 02, 04 | Hot-potato with no abilities + outpoint `Table` dedup keyed on the immutable `(deposit_txid, deposit_vout)`, never the malleable sweep txid. |
| **C2** | H | Double-claim keyed wrong: keying on sweep txid (malleable) instead of the deposit outpoint allows double-mint. | 04 | Key dedup `Table` on `(deposit_txid, deposit_vout)`; harden linkage to match `(prev_txid, prev_vout)`, not just "some input touches that tx." |
| **C3** | M | O(n) vector dedup/UTXO scans become unbounded-gas DoS as deposits grow. | 04 | Replace with `sui::table::Table` (O(1)) for `claimed` and UTXO sets. |
| **C4** | M | Append-only tree: a leaf inserted from an under-verified deposit is irreversible. | 03, 04 | Fully SPV-verify (≥6 conf) before insert; BTC reorg handled by light-client finality depth, not leaf removal. |

### D. Redemption / policy / Ika

| ID | Sev | Risk | Source specs | Mitigation |
|----|-----|------|--------------|------------|
| **D1** | H | `dWalletCap` is bearer authority: Sui has no on-chain CPI-authority hook like Solana's `__ika_cpi_authority` PDA, so the cap holder can technically sign an unapproved message. | 05 | Accepted v1 residual. Mitigated by completion-time SPV gate (an off-policy signature **cannot be finalized into a burn**) + off-chain signer guard + HSM/MPC-held cap. Open-Q: does Ika expose an approval-required-before-sign mode? |
| **D2** | H | Destination substitution: prevented only if `redemption.move` stores the RAW `scriptPubKey` (not a hash) so completion can byte-compare the SPV output. Breaking 06-move/SDK change. | 05 | Change `btc_address_hash → btc_script`; completion asserts SPV output pays `request.btc_script`. |
| **D3** | M | Overpay/underflow: native u64 subtraction in miner-fee derivation aborts when outputs > inputs, masking an overpay as a confusing arithmetic abort. | 05 | Explicit `if total_input < total_outputs { reject }` guard → clean policy reject. |
| **D4** | M | SigningApproval replay. | 05 | `used` flag + epoch expiry + request status flip to Completed (so `request_is_pending` is false). |
| **D5** | M | Uncertain BIP-341 sighash flavor (SIGHASH_DEFAULT vs SIGHASH_ALL) and whether Ika pre-/post-tags `TapSighash`. | 05 | Open question — confirm with Ika SDK before locking what the relayer stores on-chain. |

### E. Off-chain plane (indexer + SDK)

| ID | Sev | Risk | Source specs | Mitigation |
|----|-----|------|--------------|------------|
| **E1** | H | Move `StealthAnnounced` event not added → incoming transfers invisible to wallets (blocks transfer note scanning entirely). | 06, 07 | Schedule the small `transact`/`events` Move change early; emit per output commitment with `(type, ephemeral_pub, encrypted_amount, commitment, leaf_index)`. |
| **E2** | H | Indexer treated as a fund-safety oracle. It is a convenience/availability layer only. | 06, 07 | SDK MUST re-verify any Merkle path against on-chain `pool.latest_root` (live RPC) before submitting a transact. Indexer roots are hints. |
| **E3** | H | SDK silent failure swallowing: returning `confirmed:false` instead of throwing decoded Move aborts. | 07 | Throw typed errors (`SuiDryRunError`/`SuiExecutionError`) with decoded abort codes against `errors.move`. |
| **E4** | M | Non-atomic cursor advance (`service.ts:15-21`) loses progress on the final partial page → dup/stuck sync. | 06 | Atomic `ingestPage` (raw events + projections + cursor in one DB tx); always advance cursor; drain to tip. |
| **E5** | M | Dense leaf/root index gaps cause silent fund invisibility / wrong tree. | 06 | Enforce dense-prefix invariant; alarm and do not advance cursor past a gap. |
| **E6** | M | Splitter value-conservation bug burns/leaks value if a step is unbalanced. | 07 | Assert `sum(inputs) == sum(outputs)` per generated step; union of final outputs == requested outputs. |
| **E7** | M | Inter-step race: step k+1 inputs unspendable until step k's commitment lands and a fresh root is observed. | 07 | Plan executor waits for `MerkleRootUpdated` before proving/submitting the next step; resume from last finalized carry. |
| **E8** | M | Stale shared-object versions (Sui-specific, no PDA analogue): prebuilt PTB embeds versions that advance before submit. | 07 | Bounded re-fetch + rebuild + retry on `ObjectVersionUnavailable`. |
| **E9** | M | Viewing-key leakage in server-side scan (Mode B) reveals note linkability to the operator. | 06, 07 | Default-disabled (`ALLOW_VIEWKEY_SCAN=false`); SDK scans client-side (Mode A); key never in any indexer request. |
| **E10** | L | u64 amounts exceed JS safe int; `eventSeq` lexicographic sort trap. | 06 | Decimal strings for amounts; monotonic `seq` surrogate for ordering, never sort by Sui cursor. |

---

## 6. Phased Milestone Plan

Day totals are summed from per-module estimates; ranges reflect the spec ranges. Parallelizable work
is noted so calendar time is shorter than the raw developer-day sum.

### M0 — Poseidon parity gate (0.5 d) — BLOCKING
- Run Spec 03 U1/U2 + Spec 04 §9.1 vectors on a real Sui devnet/test build.
- Confirm `poseidon_bn254` == circomlibjs BN254x5 and treats each `u256` as a numeric field value.
- **Exit criteria:** all vectors green. If red, STOP and re-plan (Move-level Poseidon).

### M1 — Crypto / SPV spine (≈ 15–21 d) — CRITICAL PATH
Modules: **03 (5–6 d)** ∥ **01 (6–9 d)** → **02 (4–6 d)**. Build the shared `utxopia::bitcoin`
parser library early (feeds 02/04/05).
- 03: real depth-16 incremental Poseidon tree; remove `merkle.move` SHA256 chain; history-aware
  `is_valid_root` in `transact.move`; prune `pool.latest_root` drift.
- 01: header chain, PoW/target/work via native u256, retarget, chainwork reorg, height index,
  prune watermark, hot-potato `VerifiedInclusion`, accessor surface for 02.
- 02: Merkle inclusion climb, confirmations, full tx parser + OP_RETURN, hot-potato
  `VerifiedTxInclusion`; delete the `new_verified_deposit` stub.
- **Exit:** B1 hole closed; deposit commitments insertable into a circuit-matching tree (X1–X3 pass).

### M2 — Deposit wiring (≈ 4–6 d) — CRITICAL PATH
Module: **04**. Consume `VerifiedTxInclusion`, fee math, on-chain commitment, tree insert,
Table-based outpoint dedup + UTXO set, deposit→sweep linkage, stealth + attestation events.
- **Exit:** permissionless trustless `complete_deposit`; double-claim impossible; E2E deposit credits
  a commitment whose root matches the SDK/circuit.

### M3 — Redemption / policy / Ika (≈ 4–6 d + redemption-move surface) — PARALLEL with M1/M2
Module: **05** + the redemption Move surface it depends on.
- Real `check_redemption_signing` (amount ≤ 1 BTC, fee ≤ 50k, paused), single-use policy-bound
  `SigningApproval`, same-PTB `consume_approval`, trustless completion-time miner-fee derivation,
  `btc_address_hash → btc_script` migration, Ika SDK reconciliation in `ika.ts`/`sui-adapter.ts`.
- **Exit:** a burn can only finalize for an SPV-verified tx paying the pinned destination within
  policy; off-policy signatures cannot be finalized.

### M4 — Off-chain plane: indexer + SDK (≈ 13–19 d) — PARALLEL with M1–M3
Modules: **06 (7–10 d)** ∥ **07 (6–9 d)**. Plus the small Move `StealthAnnounced` event (~0.5 d,
scheduled into the M1 Move sprint).
- 06: SQLite-backed durable store, atomic drain-to-tip sync, dense-index gap detection, multi-RPC
  failover, projections, note-scan Mode A (trustless) + Mode B (opt-in), full HTTP API.
- 07: signer abstraction + submission lifecycle (dry-run/gas/retry/typed errors), indexer-wired
  state/notes (client-side scan), pure `splitTransfer` planner + root-wait plan executor.
- **Exit:** SDK can submit, read state, scan notes client-side; indexer is restart-safe; transfers
  scannable (given E1 event).

### M5 — E2E + hardening (≈ 4–6 d)
- Rewire `chains/sui/scripts/regtest-flow.ts` to real SPV (`verify_tx_inclusion`) instead of the
  fabricated `VerifiedBtcDeposit`.
- Full deposit → transact (incl. a >2×2 split plan) → redemption E2E on regtest + Sui localnet.
- Cross-impl golden-vector reconciliation (Move tree vs SDK vs Solana vs circuit).
- Reorg, double-claim, insufficient-conf, paused-mid-flight, destination-tamper negative tests.
- Security review of the no-abilities forgery defenses and the dWalletCap residual (D1).

### Totals
- Sum of per-module estimates: **36–51 developer-days** (01: 6–9, 02: 4–6, 03: 5–6, 04: 4–6,
  05: 4–6, 06: 7–10, 07: 6–9; M0/M5 hardening absorbed within ranges).
- With three parallel tracks (Move spine, off-chain plane, redemption), calendar time is meaningfully
  shorter than the raw sum; the **critical path is M0 → M1(03∥01→02) → M2(04) → M5**, roughly
  **24–34 developer-days serial**.

---

## 7. Open Questions Requiring a Human Decision Before Implementation

These gate or materially shape implementation. Grouped by urgency.

### Must answer before M0/M1 start
1. **Poseidon parity (A1):** confirmed-on-real-Sui that `poseidon_bn254` == circomlibjs BN254x5 and
   interprets each `u256` as a numeric field value (not LE bytes)? (Run M0 vectors; if no, the whole
   design changes.)
2. **Light-client checkpoint:** which height/hash/chainwork to anchor at deploy, and re-anchor cadence
   (new genesis vs append)? Sets the storage ceiling and the single trust root.
3. **Internal block-hash key type:** `u256` (recommended) vs `vector<u8>` for header dynamic-field
   keys — lock before implementing 01 to avoid a refactor.
4. **Confirmation accessor (B6):** does 01 expose raw `tip_height` (assumed) or a `finalized_height`
   that already bakes the 6-conf buffer? Avoid double-counting in 02/04.
5. **Regtest PoW:** skip PoW entirely (Solana behavior) vs require trivial-target PoW?

### Must answer before M2 (deposit wiring)
6. **`deposit_vout` provenance:** carried in `VerifiedBtcDeposit` by Spec 02 (recommended) vs derived
   in 04? Affects attacker-influenced index risk.
7. **`pool_script` binding:** is the Ika sweep P2TR known at pool-init (AdminCap) or configured
   post-DKG like Solana `set_pool_config`, and is the credited-output binding mandatory on mainnet?
8. **`UtxoSet` layout:** standalone shared object vs a field on `Pool` — must coordinate with the
   redemption/withdrawal spec that consumes it.
9. **`REQUIRED_CONFIRMATIONS`:** hardcoded const (6) vs AdminCap-settable `Pool` field; and the
   devnet=1 override mechanism (per-network package const recommended to keep mainnet trustless).
10. **Field-element discipline:** confirm hard-REJECT (not Solana-style reduce) for out-of-field
    npk/commitment is acceptable (recommended; honest SDK always emits canonical).

### Must answer before M3 (redemption/policy)
11. **Ika approval mode (D1, highest M3 risk):** does `@ika.xyz/sdk` / the Ika Move package expose an
    on-chain approval-required-before-sign mode? If yes, it replaces the off-chain guard with a true
    binding equivalent to `__ika_cpi_authority` and eliminates the dWalletCap-bearer risk.
12. **BIP-341 sighash flavor (D5):** SIGHASH_DEFAULT vs SIGHASH_ALL, and whether Ika applies the
    `TapSighash` tag itself or expects pre-tagged 32 bytes.
13. **Cap split:** split `RedemptionCap` into a low-privilege `ApproveCap` vs admin cap for least-
    privilege on mainnet?
14. **RedemptionQueue → Table:** migrate to `Table<u64,Request>` for O(1) policy-gate lookups, or
    document an O(n) bound + max queue depth?

### Must answer before M4 (indexer/SDK)
15. **`StealthAnnounced` event (E1):** is the Move event in-scope for this contracts sprint, or does
    the indexer ship deposit-only scanning in v1? (Blocks transfer note scanning.)
16. **Mode B server-side scan:** ever enabled in production, or strictly self-host? (Determines
    whether `/notes/scan` ships.)
17. **Single-token vs multi-token** on Sui (zkBTC only?) — determines whether `token_id` columns/fields
    are load-bearing.
18. **`/state` shape:** does 06 `/state` expose `latestMerkleRoot`/`rootIndex`/`paused` directly, or
    must 07 derive from `/events`? Affects SDK fallback paths.
19. **Plan-executor placement & step cap:** root-refresh orchestration in `sdk-sui` or pushed up to the
    high-level client; default step cap (proposed 8) and exceed behavior (hard error vs warn).
20. **Persistence/infra:** SQLite-only v1 with Postgres fast-follow; one DB per pool vs shared keyed by
    `package_id`.

### Cross-cutting
21. **Dedicated `LightClientAdminCap` vs reuse `pool::AdminCap`** (recommend dedicated).
22. **Median-time-past / 2-hour future-time header rules:** add as extra hardening or match Solana
    (skip) for parity?
23. **Not persisting `VerifiedInclusion`** (hot potato) is safe given `btc_deposit` outpoint dedup —
    confirm (spec says yes).

---

## 8. Module Index (links repeated for convenience)

| # | Module | Lang | Spec | Effort (d) | On critical path? |
|---|--------|------|------|-----------|-------------------|
| 01 | SPV Light Client | Move | [01-spv-light-client.md](./01-spv-light-client.md) | 6–9 | Yes |
| 02 | SPV Inclusion + TX Parser | Move | [02-spv-inclusion-and-tx-parser.md](./02-spv-inclusion-and-tx-parser.md) | 4–6 | Yes |
| 03 | Poseidon Merkle Tree | Move | [03-poseidon-merkle-tree.md](./03-poseidon-merkle-tree.md) | 5–6 | Yes |
| 04 | Complete-Deposit Wiring | Move | [04-complete-deposit-wiring.md](./04-complete-deposit-wiring.md) | 4–6 | Yes |
| 05 | Policy Gate + Ika Approval | Move + TS | [05-policy-gate-and-ika-approval.md](./05-policy-gate-and-ika-approval.md) | 4–6 | No (parallel) |
| 06 | Indexer Persistence + Notes | TS | [06-indexer-persistence-and-notes.md](./06-indexer-persistence-and-notes.md) | 7–10 | No (parallel) |
| 07 | SDK Submission + State | TS | [07-sdk-submission-and-state.md](./07-sdk-submission-and-state.md) | 6–9 | No (parallel) |
