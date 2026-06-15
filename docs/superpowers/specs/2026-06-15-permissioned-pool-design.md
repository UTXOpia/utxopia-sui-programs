# Permissioned Pool — Design Spec (Sui + Solana parity)

Date: 2026-06-15
Status: implemented on branch `permissioned-pool-impl` (Sui); SDK + Solana parity pending.

> History: an earlier draft of this spec gated admission with an on-chain poseidon-Merkle
> allowlist keyed on the note public key. It was simplified (see §2) to a direct
> auditor-authorization model after establishing that the target is a small,
> auditor-controlled pool (≈1–5 vetted participants), where a per-deposit auditor
> authorization is simpler and removes an entire class of proof-forgery risk.

## 1. Goal

A **permissioned pool**: a clean shielded pool controlled by an auditor. Adding value to
its commitment tree (deposit / shield) must be **authorized by the auditor**; the auditor
vets participants off-chain (KYC) and holds viewing keys so it can audit the whole pool.
This must not weaken the minting invariant (every leaf still backed by a verified deposit
or a valid spend proof) and must not change the ZK circuits. Public pools are unaffected.

A "permissioned tree" is realized as a **permissioned pool**: each `Pool` binds exactly one
commitment tree / nullifier registry, and notes cannot cross pools, so gating the pool's
value-entry points makes the whole tree auditor-controlled with no cross-pool leakage.

## 2. Scope decisions (locked)

- **Admission mechanism:** additions to a permissioned pool's commitment tree
  (`complete_deposit`, `shield`) require the **`AuditorCap`** — i.e. the auditor's backend
  key co-authorizes the transaction. There is **no on-chain allowlist** (no set, no Merkle,
  no per-identity field, no membership proof). The control point is purely "did the auditor
  authorize this add." Off-chain the auditor decides who is vetted.
- **Enforcement point:** value entry only (`complete_deposit`, `shield`). Spends
  (`transact`, `redeem`) are NOT gated — their inputs already entered through an
  auditor-authorized deposit, and no new external value enters via spends. **No circuit change.**
- **Authority model:** `permissioned` is fixed at pool creation. A dedicated `AuditorCap`
  (Sui) / `auditor: Pubkey` (Solana), separate from and non-overlapping with `AdminCap`.
  Auditor controls: authorizing deposits/shields, freeze, rotation, viewing pubkey. Auditor
  CANNOT touch funds, fees, deposit limits, verifying key, or other pools. Admin = protocol
  params/pause; auditor = admission/compliance.
- **Audit/viewing (Method Y — ECDH to auditor pubkey):** the pool stores an
  `auditor_viewing_pubkey`. The SDK additionally encrypts a copy of each note's viewing data
  to the auditor via ECDH (`shared = ECDH(ephemeral_priv, auditor_pub)`, same curve/KDF as
  the existing recipient note-encryption), carried in existing events (`BtcDepositVerified`,
  `StealthAnnounced`) as `auditor_ciphertext`. The auditor decrypts per-note with its own
  key — users never disclose a master key. On-chain stores the pubkey and forwards the
  ciphertext but does NOT verify its correctness (no ZK); the guarantee rests on the required
  official SDK + the fact that only auditor-authorized deposits enter the pool.

## 3. Data structures

### Sui — `pool.move` (`Pool` gains, defaulted for public pools)
- `permissioned: bool` — set at creation, immutable (no setter).
- `auditor_frozen: bool` — auditor's freeze of this pool's value entry (independent of admin `paused`).
- `auditor_viewing_pubkey: Option<vector<u8>>` — for Method-Y ECDH.

New capability (mirrors `AdminCap`; `pool_id` is type `ID`):
```move
public struct AuditorCap has key { id: UID, pool_id: ID }
```
`assert_auditor(cap, pool)` asserts `pool.permissioned` (else `not_permissioned`) then
`cap.pool_id == object::id(pool)` (else `wrong_auditor_cap`).

### Solana — state account
`permissioned: bool`, `auditor: Pubkey`, `auditor_frozen: bool`,
`auditor_viewing_pubkey: bytes` (compressed EC pubkey, same curve as note encryption).
Authority via `require signer == auditor` (no capability object).

## 4. Entry points (Sui; Solana mirrors)

| Function | Authority | Behavior |
|----------|-----------|----------|
| `initialize_permissioned(tree_depth, auditor: address, ctx)` | open (creation) | creates a permissioned `Pool`, mints `AuditorCap` to `auditor`. Public `initialize` unchanged. |
| `set_auditor_frozen(&AuditorCap, &mut Pool, frozen)` | auditor | freeze/unfreeze value entry (coexists with admin `paused`); emits `AuditorFrozen`. |
| `set_auditor_viewing_pubkey(&AuditorCap, &mut Pool, pubkey)` | auditor | set/rotate Method-Y viewing pubkey. |
| `rotate_commitment_tree_permissioned(&AuditorCap, ...)` | auditor | auditor-gated rotation; shares `rotate_commitment_tree_inner` with the AdminCap variant. |
| `complete_deposit(...)` / `shield<T>(...)` | public pools only | assert `!permissioned`, then shared inner logic. |
| `complete_deposit_permissioned(&AuditorCap, ...)` / `shield_permissioned<T>(&AuditorCap, ...)` | auditor | `assert_auditor` + `!auditor_frozen`, then shared inner logic. |

Both deposit entries carry a trailing `auditor_ciphertext: vector<u8>` (Method-Y; public
pools pass `vector[]`). The public and permissioned variants delegate to a single private
`*_inner` function so the deposit/shield logic is not duplicated.

## 5. Cross-chain parity

Solana mirrors the entry split: public deposit/shield instructions require `!permissioned`;
permissioned deposit/shield instructions `require signer == auditor` (+ `!auditor_frozen`).
State gains `permissioned`, `auditor`, `auditor_frozen`, `auditor_viewing_pubkey`. No Merkle,
no poseidon allowlist. The SDK exposes permissioned deposit/shield builders that include the
`AuditorCap` (Sui) / auditor signer (Solana) and the `auditor_ciphertext`.

## 6. Errors / events

- Errors: `auditor_frozen` (54), `wrong_auditor_cap` (55), `not_permissioned` (56).
- Events: `PermissionedPoolCreated`, `AuditorFrozen`, `AuditorViewingPubkeyUpdated`;
  `auditor_ciphertext` field on `BtcDepositVerified` and `StealthAnnounced`.

## 7. Testing (Sui — implemented)

- `permissioned_deposit_via_auditor_succeeds` / `permissioned_shield_via_auditor_succeeds` —
  deposit/shield through the `_permissioned` entry with the `AuditorCap` succeeds.
- `permissioned_*_rejects_when_frozen` — `set_auditor_frozen(true)` then permissioned entry → abort `auditor_frozen` (54).
- `permissioned_*_rejects_public_entry` — calling the PUBLIC entry on a permissioned pool → abort `not_permissioned` (56).
- Auditor setter tests (`auditor_sets_*`), auditor-gated rotation test.
- **Public-pool regression:** all pre-existing deposit/shield/transact tests pass unchanged
  (public pools skip every permissioned branch).

## 8. Notes / constraints

- Adding params (`auditor_ciphertext`) and new public entries to `complete_deposit` / `shield`
  is an **upgrade-incompatible** public-signature change → fresh package deploy + re-init per
  the documented procedure, not an in-place upgrade.
- A permissioned pool accepts NO deposits except through the auditor-authorized entries — there
  is no permissionless path into it (the public entries abort on a permissioned pool).
- Method-Y ciphertext is not on-chain-verified; the viewing guarantee rests on the official
  SDK plus auditor-only admission. Strengthening to an in-circuit guarantee is out of scope.
