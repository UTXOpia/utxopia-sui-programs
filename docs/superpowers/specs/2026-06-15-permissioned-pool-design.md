# Permissioned Pool — Design Spec (Sui + Solana parity)

Date: 2026-06-15
Status: approved (brainstorming) — pending implementation plan

## 1. Goal

Add a **permissioned pool** variant to Utxopia: a shielded pool whose commitment
tree only accepts value from an auditor-approved allowlist, with an independent
auditor authority for compliance control and selective audit/viewing — without
weakening the existing minting invariant (every leaf must be backed by a verified
deposit or a valid spend proof) and without changing the ZK circuits.

A "permissioned tree" is realized as a **permissioned pool**: each `Pool` binds
exactly one commitment tree, one nullifier registry, etc., and notes cannot cross
pools (roots/nullifiers are pool-scoped). So enforcing the allowlist at the
pool's value-entry points makes the whole tree's anonymity set vetted, with no
cross-pool leakage.

## 2. Scope decisions (locked)

- **Enforcement point:** at value entry only (`complete_deposit`, `shield`). Spends
  (`transact`, `redeem`) are NOT gated — their inputs already entered through an
  allowlisted deposit, and no new external value enters via spends. **No circuit
  change.**
- **Allowlist storage:** Merkle root on-chain (`allowlist_root`), membership proof
  supplied at deposit. List contents stay off-chain. Hash = poseidon (cross-chain
  shared via the existing `poseidon-parity` package). Leaf key = note public key
  (`npk_field`), the identity field common to both deposit paths.
- **Authority model:** `permissioned` is fixed at pool creation. A dedicated
  `AuditorCap` (Sui) / `auditor: Pubkey` (Solana), separate from and
  non-overlapping with `AdminCap`. Auditor controls: allowlist root, auditor
  freeze, rotation, auditor viewing pubkey. Auditor CANNOT touch funds, fees,
  deposit limits, verifying key, or other pools. Admin and auditor check each
  other (admin = protocol params/pause; auditor = admission/compliance).
- **Audit/viewing (Method Y — ECDH to auditor pubkey):** the pool stores an
  `auditor_viewing_pubkey`. Each note's SDK additionally encrypts a copy of the
  note's viewing data to the auditor via ECDH (`shared = ECDH(ephemeral_priv,
  auditor_pub)`), carried in events. Auditor decrypts per-note with its own key —
  the user never discloses a master viewing key. On-chain stores the pubkey and
  carries the ciphertext but does NOT verify ciphertext correctness (no ZK);
  the guarantee rests on the required official SDK + the KYC allowlist.

## 3. Data structures

### Sui — `pool.move` (`Pool` gains, defaulted for public pools)
- `permissioned: bool` — set at creation, immutable.
- `allowlist_root: Option<vector<u8>>` — 32-byte poseidon root. `none` ⇒ fail-closed
  (no deposits until the auditor sets it).
- `auditor_frozen: bool` — auditor's independent freeze of this tree's value entry.
- `auditor_viewing_pubkey: Option<vector<u8>>` — for Method Y ECDH.

New capability:
```move
public struct AuditorCap has key, store { id: UID, pool_id: address }
```
`assert_auditor(cap, pool)` checks `cap.pool_id == object::id(pool) && pool.permissioned`.

### Solana — state account
`permissioned: bool`, `allowlist_root: [u8;32]`, `auditor: Pubkey`,
`auditor_frozen: bool`, `auditor_viewing_pubkey: bytes` (compressed EC pubkey, same
curve as the existing note-encryption scheme). Authority via `require signer ==
auditor` (no capability object).

## 4. Entry points (Sui; Solana mirrors)

| Function | Authority | Behavior |
|----------|-----------|----------|
| `initialize_permissioned(tree_depth, auditor: address, ctx)` | open (creation) | creates a permissioned `Pool` (`permissioned=true`), mints `AuditorCap` to `auditor`. Public `initialize` unchanged. |
| `set_allowlist_root(&AuditorCap, &mut Pool, root: vector<u8>)` | auditor | update allowlist root; emits `AllowlistRootUpdated`. |
| `set_auditor_frozen(&AuditorCap, &mut Pool, frozen: bool)` | auditor | freeze/unfreeze value entry (coexists with admin `paused`); emits `AuditorFrozen`. |
| `set_auditor_viewing_pubkey(&AuditorCap, &mut Pool, pubkey)` | auditor | set/rotate Method-Y viewing pubkey. |
| `rotate_commitment_tree_permissioned(&AuditorCap, ...)` | auditor | auditor-gated rotation, mirroring the existing AdminCap `rotate_commitment_tree` guards. |
| `complete_deposit(...)`, `shield<T>(...)` | unchanged callers | gain a membership-proof parameter; enforce allowlist when `permissioned`. |

## 5. Allowlist verification — new `lib/allowlist.move`

```move
/// poseidon Merkle membership: recompute the root from `leaf` up using `siblings`
/// and per-level direction bits in `index_bits` (bit i: 0 = current is left child).
public fun verify_membership(
    root: vector<u8>, leaf: u256,
    siblings: vector<vector<u8>>, index_bits: u64,
): bool
```
Internal nodes: `poseidon_bn254(&vector[left, right])`. Leaf = `npk_field`.

Enforcement inserted into both deposit entries:
```move
if (pool::is_permissioned(pool)) {
    assert!(!pool::auditor_frozen(pool), errors::auditor_frozen());
    let root = pool::allowlist_root(pool);            // none => abort (fail-closed)
    assert!(
        allowlist::verify_membership(root, npk_field, siblings, index_bits),
        errors::not_allowlisted(),
    );
};
```
Public pools skip this entirely — behavior unchanged.

## 6. Audit/viewing (Method Y)

- `auditor_viewing_pubkey` stored on the pool (auditor-set).
- SDK, when constructing a note for a permissioned pool, derives
  `shared = ECDH(ephemeral_priv, auditor_pub)` and encrypts a copy of the note
  viewing data (amount, blinding, owner) → `auditor_ciphertext`. The ECDH curve +
  KDF MUST match the existing recipient note-encryption scheme (reuse the same
  ephemeral key already produced per note) — no new crypto primitive.
- Carried out-of-band of the size-limited BTC OP_RETURN: emitted in the Sui
  event at `complete_deposit` / `shield` (new `auditor_ciphertext` event field).
  On-chain stores/forwards only; no correctness check.
- Auditor scans events, does ECDH with its private key, decrypts per-note.

## 7. Cross-chain parity

- poseidon Merkle identical on both chains (existing `poseidon-parity`).
- Shared SDK allowlist builder: build tree, root, and membership proofs; one
  source of truth consumed by both Sui and Solana adapters.
- Sui adapter: thread membership proof (siblings + index_bits) into deposit/shield
  PTBs; pass `auditor_ciphertext`.
- Solana program: mirror instructions (`init_permissioned`, `set_allowlist_root`,
  `set_auditor_frozen`, `set_auditor_viewing_pubkey`), state fields, poseidon
  membership verify, and signer-based auditor checks; deposit instructions verify
  the proof.

## 8. Errors / events

- Errors: `not_allowlisted`, `auditor_frozen`, `wrong_auditor_cap`,
  `not_permissioned` (auditor op on a public pool), `allowlist_root_unset`.
- Events: `PermissionedPoolCreated`, `AllowlistRootUpdated`, `AuditorFrozen`,
  `AuditorViewingPubkeyUpdated`; extend deposit events with `auditor_ciphertext`.

## 9. Testing

- `allowlist.move` unit tests: poseidon Merkle membership against SDK/circomlib
  parity vectors (mirroring `commitment_tree_tests::u1_hash_node_matches_circomlib`);
  reject tampered sibling/leaf/index.
- Permissioned deposit/shield: valid proof passes; non-allowlisted rejected;
  rejected when `auditor_frozen`; rejected when `allowlist_root` unset (fail-closed);
  **public pool unaffected** (regression).
- Authority isolation: `AuditorCap` cannot call admin functions; `AdminCap` cannot
  call auditor functions; cap bound to wrong pool rejected.
- Solana: parallel test suite. SDK: allowlist builder + parity vector test.

## 10. Notes / constraints

- Adding parameters to `complete_deposit` / `shield` is an **upgrade-incompatible**
  public-signature change (same as the H1 redemption-sighash fix) → requires fresh
  package deploy + re-init per the documented procedure, not an in-place upgrade.
- `allowlist_root == none` is **fail-closed**: a freshly created permissioned pool
  accepts no deposits until the auditor sets the root.
- Method-Y ciphertext is not on-chain-verified; the viewing guarantee relies on the
  official SDK plus the KYC allowlist. Strengthening it to an in-circuit guarantee
  is explicitly out of scope (would require circuit + trusted-setup changes).
