# 07 — Sui SDK: Transaction Submission, State Queries, and >2×2 Transfer Splitter

Status: spec (implementation-ready)
Module: `packages/sdk-sui` (TypeScript)
Owner: SDK
Depends on: `05-policy-gate-and-ika-approval.md`, `06-indexer-api.md` (indexer HTTP surface), `packages/sdk-core` (`UTXOpiaChainAdapter` contract)

---

## 1. Goal & what it replaces

Make `@utxopia/sdk-sui` a complete, signer-capable adapter so `@utxopia/sdk`
consumers reach **parity with the Solana SDK** for submission and state reads,
plus add the accepted circuit-cap workaround (client-side transfer splitting).

Concretely, replace these stubs in
`packages/sdk-sui/src/sui-adapter.ts`:

| Location (current code) | Stub behavior | Replace with |
|---|---|---|
| `submitTransaction()` (`sui-adapter.ts:~344`) | `throw new Error("Sui transaction submission is not implemented yet")` | Real `@mysten/sui` signer-based submission: build full tx from PTB kind, set sender/gas, dry-run, sign, execute, wait-for-finality, surface effects/errors. |
| `getPoolState()` (`sui-adapter.ts:~46`) | returns hard-coded `{ paused: false, latestMerkleRoot: "", treeDepth: 16 }` | Query indexer `/state` (spec 06) + live Sui object fallback. |
| `getLatestMerkleRoot()` (`sui-adapter.ts:~58`) | returns `{ root: "", index: 0, observedAt: epoch0 }` | Derive from indexer `MerkleRootUpdated` events / `/state`. |
| `getNotes()` (`sui-adapter.ts:~67`) | `throw new Error("Sui note scanning requires the Sui indexer API implementation")` | Fetch announcements/events from indexer `/events`, scan client-side with viewing key (privacy-preserving, mirrors Solana `scanUnifiedNotes`). |
| (new) transfer splitter | — | `splitTransfer()` helper + integration in the high-level transact path so >2×2 logical transfers are chained as ≤2×2 PTBs. |

Reference for the desired submission/lifecycle behavior already exists in the
repo as a script helper:
`chains/sui/scripts/signing.ts::executeBuiltTransaction` (uses
`signAndExecuteTransaction` + `waitForTransaction`, `setGasBudget`,
`showEffects/showEvents/showObjectChanges`). The SDK must generalize that into a
pluggable signer abstraction (no `sui` CLI / keystore-file dependency in the
library path).

Solana parity reference (the API surface to mirror):
`sdk/src/client.ts` — `UTXOpiaClient.init`, `loginWithSeed`, `getNotes(tokens)`,
`getBalance`; and the adapter contract in
`packages/sdk-core/src/chain-adapter.ts` (`UTXOpiaChainAdapter`).

---

## 2. Data model & signer abstraction

The library MUST NOT depend on the local `sui` CLI or a keystore file (that is a
script-only convenience in `scripts/signing.ts`). Introduce a signer interface
so consumers inject keypairs, hardware/relayer signers, or wallet adapters.

```ts
// packages/sdk-sui/src/signer.ts
import type { Transaction } from "@mysten/sui/transactions";

export interface SuiTransactionSigner {
  /** Bech32/0x Sui address that will be the tx sender + gas owner. */
  getAddress(): Promise<string> | string;
  /**
   * Sign the BCS-serialized intent message for `tx` and return the
   * base64 signature(s). Implementations wrap @mysten/sui keypairs,
   * wallet-standard adapters, or remote signers.
   */
  signTransaction(tx: Transaction): Promise<{ signature: string | string[]; bytes?: Uint8Array }>;
}
```

Provide two built-in implementations:

```ts
// Ed25519 keypair signer (server/relayer/tests)
export class Ed25519SuiSigner implements SuiTransactionSigner { /* wraps Ed25519Keypair */ }

// Wallet-standard passthrough (browser dApp)
export class WalletStandardSuiSigner implements SuiTransactionSigner { /* wraps wallet.signTransaction */ }
```

Extend `UTXOpiaSuiAdapterConfig` (in `sui-adapter.ts`) with:

```ts
interface UTXOpiaSuiAdapterConfig {
  // ...existing fields...
  indexerUrl?: string;            // already present; now required for state/notes
  network?: "mainnet" | "testnet" | "devnet" | "localnet";
  signer?: SuiTransactionSigner;  // optional; required only for submit
  gasBudget?: bigint;             // override; default = dry-run estimate * 1.2 (see §6)
  finality?: "executed" | "checkpointed"; // wait granularity, default "executed"
}
```

`SignedTransaction` (sdk-core) carries only `{ chain, kind, bytes }`. For Sui the
adapter needs the signature too. Two compliant options — pick **(A)**:

- **(A) Adapter-internal sign+submit.** Add `signAndSubmit(tx, signer?)` to the
  adapter and keep `submitTransaction(signed)` for the case where the caller
  already produced a signed envelope. Internally store the signature on an
  extended `SuiSignedTransaction` that widens the sdk-core type:

  ```ts
  export interface SuiSignedTransaction extends BaseSignedTransaction {
    chain: "sui";
    kind: "sui-programmable-transaction-block";
    signature: string | string[]; // base64
    sender: string;
  }
  ```

  `submitTransaction` narrows `SignedTransaction` to `SuiSignedTransaction` (type
  guard); throws a typed error if `signature`/`sender` missing.

Object model note (Sui vs Solana PDAs): Solana derives accounts by seeds
(deterministic, no version). Sui shared objects need
`{ objectId, initialSharedVersion, mutable }` and owned objects need
`{ objectId, version, digest }` (already handled by `sharedObject`/`objectRef`
in the adapter). The submission path therefore must reconcile **object versions
at submit time** — see §6 (stale-version / re-fetch handling).

---

## 3. Function signatures

```ts
class UTXOpiaSuiAdapter implements UTXOpiaChainAdapter {
  // ── submission ──────────────────────────────────────────────
  /** Convert a PTB-kind envelope into a full Transaction, set sender/gas. */
  private async finalizeTransaction(
    bytes: Uint8Array,
    sender: string,
    gasBudget?: bigint,
  ): Promise<Transaction>;

  /** Dry-run; throws SuiDryRunError on non-success status. Returns gas estimate. */
  private async dryRun(tx: Transaction, sender: string): Promise<{ gasUsed: bigint; raw: DryRunTransactionBlockResponse }>;

  /** One-shot: finalize -> dry-run -> sign -> execute -> wait. */
  async signAndSubmit(
    unsigned: SuiUnsignedTransaction,
    signer?: SuiTransactionSigner,
    opts?: { skipDryRun?: boolean; gasBudget?: bigint },
  ): Promise<TransactionResult>;

  /** sdk-core contract: caller supplies an already-signed SuiSignedTransaction. */
  async submitTransaction(tx: SignedTransaction): Promise<TransactionResult>;

  // ── state queries (wire to indexer) ─────────────────────────
  async getPoolState(): Promise<PoolState>;
  async getLatestMerkleRoot(): Promise<MerkleRoot>;
  async getNotes(input: NoteScanInput): Promise<Note[]>;

  // ── >2×2 splitter ───────────────────────────────────────────
  /**
   * Decompose a logical transfer whose arity would exceed 2×2 into an
   * ordered list of ≤2×2 TransactInput steps. Pure/deterministic; no I/O.
   */
  splitTransfer(input: TransactInput): TransactPlan;

  /** Build + (optionally) submit each step of a plan in dependency order. */
  async buildTransactPlan(input: TransactInput): Promise<SuiUnsignedTransaction[]>;
}

interface TransactStep {
  nInputs: number;            // ∈ {1,2}
  nOutputs: number;           // ∈ {1,2}
  inputNotes: Note[];         // ≤2, references prior step outputs by handle
  outputs: TransactInput["outputs"]; // ≤2; may include an intermediate "change to self"
  intermediate: boolean;      // true if an output is a synthetic carry note
}
interface TransactPlan {
  steps: TransactStep[];
  finalOutputs: TransactInput["outputs"];
}
```

Indexer HTTP client (new file `packages/sdk-sui/src/indexer-client.ts`):

```ts
class SuiIndexerClient {
  constructor(baseUrl: string, packageId: string);
  getState(): Promise<{ packageId: string; latestMerkleRoot?: string; rootIndex?: number; paused?: boolean; observedAt?: string }>;
  getEvents(cursor?: { txDigest: string; eventSeq: string }, types?: SuiUtxopiaEventType[]): Promise<NormalizedSuiUtxopiaEvent[]>;
  // pages until exhausted; used by getNotes
  fetchAllAnnouncements(fromCursor?: ...): AsyncGenerator<NormalizedSuiUtxopiaEvent>;
}
```

---

## 4. Algorithm (step by step)

### 4.1 `signAndSubmit`
1. Resolve `signer = opts?.signer ?? this.config.signer` (throw typed
   `SuiSignerRequiredError` if absent). `sender = await signer.getAddress()`.
2. `tx = Transaction.fromKind(unsigned.bytes)` then `tx.setSender(sender)`.
   (Mirrors `scripts/signing.ts::executeBuiltTransaction`.)
3. Gas: if `opts.gasBudget`/`config.gasBudget` set → `tx.setGasBudget(...)`.
   Else run dry-run (§4.2) to obtain estimate, set
   `gasBudget = ceil(estimate.gasUsed * 1.2)` clamped to a configurable max.
4. Dry-run (unless `skipDryRun`): call
   `client.dryRunTransactionBlock({ transactionBlock: await tx.build({ client }) })`.
   If `effects.status.status !== "success"`, throw `SuiDryRunError` carrying
   `status.error`, the failing command index, and any abort code (decode against
   the Move `errors` module — see §7).
5. Sign: `const { signature } = await signer.signTransaction(tx)`.
6. Execute:
   ```ts
   const res = await client.signAndExecuteTransaction({
     transaction: tx, signer: /* raw bytes path */,
     options: { showEffects: true, showEvents: true, showObjectChanges: true },
   });
   ```
   For the injected-signer path, prefer the explicit
   `executeTransactionBlock({ transactionBlock: bytes, signature })` so we are
   not coupled to `@mysten/sui` keypair internals.
7. Finality: `await client.waitForTransaction({ digest: res.digest, options: { showEffects: true } })`.
   If `config.finality === "checkpointed"`, additionally poll until
   `res.checkpoint` is set.
8. Map to `TransactionResult`:
   ```ts
   { chain: "sui", digest, confirmed: status === "success",
     checkpoint, eventCursor: lastEvent ? `${digest}:${lastEvent.eventSeq}` : undefined }
   ```
   On `status === "failure"` after execution, throw `SuiExecutionError`
   (effects + decoded abort), do not return `confirmed: false` silently.

### 4.2 State queries
- `getPoolState()`: GET `${indexerUrl}/state`. Map
  `{ paused, latestMerkleRoot, rootIndex, treeDepth: 16, poolId: config.poolObjectId }`.
  Fallback if `paused`/root absent in state: read the live pool shared object via
  `client.getObject({ id: poolObjectId, options: { showContent: true } })` and
  parse the Move struct fields (`paused`, `merkle_root`). This dual-path mirrors
  Solana reading pool account directly.
- `getLatestMerkleRoot()`: prefer `/state.latestMerkleRoot` + `rootIndex` +
  `observedAt`. If indexer lacks it, scan `/events?types=MerkleRootUpdated`,
  take the highest cursor, read `payload.root` / `payload.index`. (Event types
  enumerated in `chains/sui/indexer/src/types.ts`.)
- `getNotes(input)`: privacy-preserving client-side scan (do NOT send viewing
  key to indexer):
  1. Page `/events?types=CommitmentInserted` (deposit/transfer announcements
     are emitted as events per the Sui events module; equivalent to Solana
     `sol_log_data` announcements scanned in `sdk/src/client.ts::getNotes`).
  2. For each announcement, run the existing client-side scan logic
     (`scanUnifiedNotes`-equivalent: ECDH against `viewingKey`, npk match,
     decrypt amount). The scan crypto is chain-agnostic and reused from
     `@utxopia/sdk` core (Baby Jubjub ECDH + Ed25519 viewing key).
  3. Filter by `tokenIds` when provided; dedupe by `leafIndex` (same dedup as
     Solana). Return `Note[]` with `commitment`, `leafIndex`, `amount`,
     `tokenId`, optional `nullifier` (computed locally).

### 4.3 `splitTransfer` (>2×2 → chain of ≤2×2)
This is the **accepted circuit-cap workaround** (Sui groth16 ≤ 8 public inputs ⇒
catalog capped at 1×1/1×2/2×1/2×2; see `sdk-core/src/sui-circuits.ts`,
`SUI_GROTH16_MAX_PUBLIC_INPUTS = 8`). The SDK transparently chains transacts.

Inputs: `N = input.inputNotes.length`, `M = input.outputs.length`. If
`N ≤ 2 && M ≤ 2` → single step, return `{ steps: [thatStep], finalOutputs }`.

Otherwise decompose. Invariant at every step: **sum(inputs) == sum(outputs)**
(value conservation; the circuit enforces it, so the planner must produce
balanced steps or proving fails).

- **Consolidate inputs (N>2):** repeatedly take 2 input notes → 1 output note
  (a 2×1 "carry to self" with combined value), producing
  `ceil(N/2)` notes, recursing until ≤2 carry notes remain. Carry notes are
  self-addressed (recipient = sender's own next stealth address) so they re-enter
  scanning. Each carry is a real on-chain commitment; the next step references it
  by `leafIndex`/commitment once finalized.
- **Fan out outputs (M>2):** from the (≤2) consolidated input(s), emit outputs in
  ≤2 per step. A step that still has remaining real outputs to emit produces
  `[realOutput, changeToSelf]` (1 real + 1 carry), and the carry funds the next
  step. The last step emits the final 1–2 real outputs with no carry.
- **General N×M:** consolidate first, then fan out. Worst case
  `~ceil((N-1)) + ceil((M-1))` steps; bounded and logged.

`buildTransactPlan` then, for each step in order:
  1. (Caller/prover) generate the Groth16 proof for that ≤2×2 shape via the
     existing prover, producing `vkHash/publicInputs/proofPoints/nullifiers/
     commitmentsOut` matching the step.
  2. Call existing `buildTransactTransaction(stepInput)` (unchanged PTB builder).
  3. Return the ordered `SuiUnsignedTransaction[]`. Submission is sequential:
     step k+1's input notes only become spendable after step k is finalized
     (its commitment is in the tree and a fresh `latestMerkleRoot` is observed).
     `signAndSubmitPlan(plan)` loops `signAndSubmit` + waits for the indexer to
     reflect the new root before proving the next step.

> The planner is pure and deterministic; proof generation + root refresh are
> orchestrated by the high-level client, not inside `splitTransfer`.

---

## 5. Crypto / parameters relevant to the SDK

The SDK does not introduce new on-chain crypto; it must stay byte-exact with
the circuit + Move contracts:
- **Public-input ordering**: `[merkleRoot, boundParamsHash, nullifiers...,
  commitmentsOut...]` (from `sdk-core/src/sui-circuits.ts`
  `joinSplitPublicInputLabels`). The splitter must keep this ordering per step.
- **Field canonicalization**: every 32-byte scalar handed to the PTB
  (`publicInputs`, `nullifiers`, `commitmentsOut`) MUST be a canonical BN254
  field element (< r) in the byte order the Move `verifier`/`merkle` expect (see
  spec 02/04). The SDK validates `value < BN254_R` before building and throws,
  rather than letting an on-chain abort happen.
- **Commitment** = `Poseidon(npk, tokenId, amount)` and **nullifier** =
  `Poseidon(nullifyingKey, leafIndex)` — reused verbatim from `@utxopia/sdk`
  core so carry notes produced by the splitter hash identically on-chain.
- **Token id**: `zkBTC = 0x7a627463`. Splitter carry notes inherit the source
  note's `tokenId`.

---

## 6. Gas / performance

- **Gas budgeting**: default = dry-run `gasUsed * 1.2`, clamped to
  `config.gasBudget` max (env `UTXOPIA_SUI_GAS_BUDGET` default `100_000_000`,
  same as `scripts/signing.ts`). Avoid hard-coding; transact PTBs (Groth16
  verify + Poseidon tree insert) are heavier than redemption PTBs.
- **Dry-run caching**: when submitting a multi-step plan, dry-run only changes
  meaningfully when object versions change; still dry-run each step because the
  Merkle root shared object mutates between steps.
- **Stale shared-object versions**: the prebuilt PTB kind embeds object
  versions. Between build and submit, the pool/nullifier/root objects may have
  advanced. On `ObjectVersionUnavailable`/`ObjectVersionTooHigh` execution
  errors, the adapter must re-fetch current `initialSharedVersion`/`version`,
  rebuild the PTB, and retry once (bounded retry, surfaced in
  `TransactionResult` metadata). This is a Sui-specific concern with no Solana
  analogue (PDAs are versionless).
- **Indexer paging**: `getNotes` pages `/events`; cache the last cursor and
  expose `fromCursor` (already in `NoteScanInput`) so re-scans are incremental,
  matching the Solana incremental-scan pattern.
- **Plan length blow-up**: warn/cap when a split plan exceeds a configurable
  step limit (default 8) to avoid silently chaining dozens of on-chain txs.

---

## 7. Risks, edge cases, security pitfalls

1. **Silent failure swallowing**: never return `confirmed: false` on an
   execution failure — throw a typed error with decoded Move abort. Decode abort
   codes against the `errors` Move module (`chains/sui/contracts/sources/errors.move`).
2. **Viewing-key leakage**: `getNotes` must scan client-side. Never include the
   viewing key in any indexer request/query string.
3. **Splitter value-conservation bug**: an unbalanced step makes the prover
   fail (best case) or, if a balanced-but-wrong split, leaks/burns value. Unit
   tests must assert `sum(inputs) == sum(outputs)` for every generated step and
   that the union of final outputs equals the original requested outputs.
4. **Ordering / race between steps**: step k+1 inputs are unspendable until step
   k's commitment is in the tree. Submitting eagerly causes "unknown merkle
   root"/"commitment not found" aborts. The plan executor must wait for the new
   root (indexer `MerkleRootUpdated`) before proving/submitting the next step.
5. **Non-canonical field elements**: feeding `value ≥ r` to `poseidon_bn254`/
   groth16 verify aborts on-chain (wasted gas) — validate client-side (§5).
6. **Stale object versions** (§6) — bounded re-fetch+retry, else surface clearly.
7. **Gas exhaustion**: dry-run before sign so we never broadcast a tx that will
   abort for insufficient budget; surface the estimate to callers.
8. **Double-submit / nullifier replay**: if a step is submitted twice, the
   second aborts on nullifier-already-spent. Treat that specific abort as
   idempotent-success when the digest of the prior submit is known.
9. **Partial-plan failure**: if step k succeeds and k+1 fails, carry notes are
   real on-chain spendable notes owned by the user — the high-level client must
   resume from the last finalized carry, not restart, to avoid orphaning value.

---

## 8. Dependencies on other modules in this design set

- **06 Indexer API** (`/state`, `/events`): `getPoolState`,
  `getLatestMerkleRoot`, `getNotes` all read from it. Requires spec 06 to expose
  `latestMerkleRoot`/`rootIndex`/`paused` in `/state` and `CommitmentInserted` /
  `MerkleRootUpdated` events in `/events` (event taxonomy already in
  `indexer/src/types.ts`).
- **04 complete-deposit / 03 Poseidon Merkle**: commitment + root semantics the
  splitter and note scan rely on (carry-note hashing must match on-chain).
- **05 Policy gate / Ika**: redemption submission reuses the same
  `signAndSubmit` path; no special-casing beyond object refs.
- **sdk-core** (`chain-adapter.ts`): the `UTXOpiaChainAdapter` contract this
  implements; `SuiSignedTransaction`/`SuiSignerRequiredError` are additive and
  must not break the Solana adapter.
- **@utxopia/sdk core scan/prover**: reused verbatim for note scanning and proof
  generation (chain-agnostic crypto).

---

## 9. Test matrix

### Unit (no network)
- `splitTransfer`:
  - 1×1, 1×2, 2×1, 2×2 → single step, `intermediate=false`.
  - 3×1, 1×3, 3×3, 4×2, 2×4, 5×5, 7×7 → plan whose every step has
    `nInputs≤2 && nOutputs≤2`; value conserved per step; union of final outputs
    == requested outputs; step count within bound.
  - Token-id preserved on carry notes; recipient of carries = self.
  - Public-input ordering preserved per step.
- Field canonicalization: scalar `== r-1` accepted, `== r` and `> r` rejected
  with a typed error.
- Gas budgeting: explicit `gasBudget` honored; absent → uses `estimate*1.2`.
- Signer abstraction: `Ed25519SuiSigner.getAddress/signTransaction`;
  missing-signer throws `SuiSignerRequiredError`.
- `submitTransaction` type guard: rejects envelope lacking `signature`/`sender`.

### Integration (mocked RPC + mocked indexer)
- Dry-run success → sign → execute → wait → `TransactionResult.confirmed=true`,
  correct `digest`/`checkpoint`/`eventCursor`.
- Dry-run failure → `SuiDryRunError` with decoded abort code (assert against
  `errors.move` constant).
- Execution failure post-broadcast → `SuiExecutionError` (not silent
  `confirmed:false`).
- Stale shared version → simulate `ObjectVersionUnavailable`, assert one
  re-fetch+rebuild+retry then success.
- Nullifier-already-spent on re-submit → idempotent success path.
- `getPoolState`/`getLatestMerkleRoot`: from `/state`; fallback to live object
  read when state omits root; fallback to `MerkleRootUpdated` events.
- `getNotes`: mocked `/events` announcements → correct scanned notes; viewing
  key never appears in any request; `fromCursor` yields incremental results;
  dedupe by `leafIndex`.

### E2E (regtest + Sui localnet/testnet)
- Replace `scripts/regtest-flow.ts` script-level `executeTransactionKind` with
  adapter `signAndSubmit` and assert identical end-state.
- Full >2×2 transfer (e.g. 3×3) executed as a chained plan against a live
  Poseidon tree; final balances reconcile; intermediate carries spent.
- Parity check: same logical transfer produces equivalent final note set on Sui
  (chained) vs Solana (single proof).

---

## 10. Effort & open questions

**Effort: 6–9 developer-days.**
- Signer abstraction + submission lifecycle (dry-run/gas/retry/error decode): ~2.5d
- Indexer client + state/notes wiring + client-side scan reuse: ~2d
- `splitTransfer` planner + plan executor (root-wait orchestration): ~2.5d
- Tests (unit + mocked integration + E2E wiring): ~2d

**Open questions**
1. Does spec-06 `/state` expose `latestMerkleRoot`/`rootIndex`/`paused`
   directly, or must the SDK derive them from `/events`? (Affects fallback code
   paths.)
2. Are deposit/transfer announcements emitted as `CommitmentInserted` events
   with the ephemeral/npk/encrypted-amount payload, or via a separate event? Need
   the exact payload schema to wire `getNotes`.
3. Should `submitTransaction(SignedTransaction)` widen the sdk-core type
   (`SuiSignedTransaction`) or should we standardize on adapter-internal
   `signAndSubmit` and treat sdk-core `submitTransaction` as "already-signed
   bytes only"? (Leaning: support both; `signAndSubmit` is primary.)
4. Plan-executor placement: keep root-refresh orchestration in `sdk-sui` or push
   it up to the high-level `@utxopia/sdk` client (closer to Solana's client)?
5. Step-count cap default (proposed 8) and behavior on exceed: hard error vs
   warn-and-proceed.
6. Retry policy bound for stale-version (1 vs N) and whether to expose it in
   config.
