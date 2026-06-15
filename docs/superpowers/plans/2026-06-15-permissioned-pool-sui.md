# Permissioned Pool (Sui contract) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an auditor-controlled permissioned pool to the Sui Move contracts: deposits/shields into a permissioned pool require a poseidon-Merkle allowlist membership proof, gated by a dedicated `AuditorCap`, with auditor-set allowlist root / freeze / rotation / viewing pubkey — no ZK circuit change.

**Architecture:** A permissioned pool is a normal `Pool` with `permissioned = true`, fixed at creation. New `lib/allowlist.move` verifies poseidon-Merkle membership of the note public key against an on-chain `allowlist_root`. The two value-entry functions (`btc_deposit::complete_deposit`, `token_registry::shield`) gain a membership-proof parameter and enforce it only when the pool is permissioned. Public pools are unaffected (`permissioned = false`, branch skipped). Audit/viewing is Method-Y ECDH: the pool stores an `auditor_viewing_pubkey`; the auditor ciphertext rides existing events (stored, not verified on-chain).

**Tech Stack:** Sui Move (edition 2024.beta), `sui::poseidon::poseidon_bn254`, existing `commitment_tree` field helpers, `sui move test`.

**Scope:** This plan covers the Sui contract only. SDK (allowlist builder + adapter proof wiring) and Solana parity are separate plans.

**Spec:** `docs/superpowers/specs/2026-06-15-permissioned-pool-design.md`

---

### Task 1: Error codes

**Files:**
- Modify: `contracts/sources/lib/errors.move`

- [ ] **Step 1: Add the constants** after line 53 (`E_TIMESTAMP_TOO_FAR: u64 = 52;`)

```move
    const E_NOT_ALLOWLISTED: u64 = 53;
    const E_AUDITOR_FROZEN: u64 = 54;
    const E_WRONG_AUDITOR_CAP: u64 = 55;
    const E_NOT_PERMISSIONED: u64 = 56;
    const E_ALLOWLIST_ROOT_UNSET: u64 = 57;
```

- [ ] **Step 2: Add the accessors** before the closing `}` (after line 105)

```move
    public fun not_allowlisted(): u64 { E_NOT_ALLOWLISTED }
    public fun auditor_frozen(): u64 { E_AUDITOR_FROZEN }
    public fun wrong_auditor_cap(): u64 { E_WRONG_AUDITOR_CAP }
    public fun not_permissioned(): u64 { E_NOT_PERMISSIONED }
    public fun allowlist_root_unset(): u64 { E_ALLOWLIST_ROOT_UNSET }
```

- [ ] **Step 3: Build**

Run: `sui move build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add contracts/sources/lib/errors.move
git commit -m "errors: add permissioned-pool error codes (53-57)"
```

---

### Task 2: Events

**Files:**
- Modify: `contracts/sources/lib/events.move`

- [ ] **Step 1: Add event structs** after `PoolPaused` (line 11)

```move
    public struct PermissionedPoolCreated has copy, drop {
        pool_id: address,
        auditor: address,
    }
    public struct AllowlistRootUpdated has copy, drop {
        pool_id: address,
        root: vector<u8>,
    }
    public struct AuditorFrozen has copy, drop {
        pool_id: address,
        frozen: bool,
    }
    public struct AuditorViewingPubkeyUpdated has copy, drop {
        pool_id: address,
        pubkey: vector<u8>,
    }
```

- [ ] **Step 2: Add emit functions** (place next to `pool_paused`, mirroring its style)

```move
    public(package) fun permissioned_pool_created(pool_id: address, auditor: address) {
        event::emit(PermissionedPoolCreated { pool_id, auditor })
    }
    public(package) fun allowlist_root_updated(pool_id: address, root: vector<u8>) {
        event::emit(AllowlistRootUpdated { pool_id, root })
    }
    public(package) fun auditor_frozen(pool_id: address, frozen: bool) {
        event::emit(AuditorFrozen { pool_id, frozen })
    }
    public(package) fun auditor_viewing_pubkey_updated(pool_id: address, pubkey: vector<u8>) {
        event::emit(AuditorViewingPubkeyUpdated { pool_id, pubkey })
    }
```

Note: the `BtcDepositVerified` event gains an `auditor_ciphertext` field, but that
change is made in **Task 7** together with its only caller, so this task stays
purely additive and every commit builds.

- [ ] **Step 4: Build**

Run: `sui move build`
Expected: builds clean (these additions are new, non-breaking declarations).

- [ ] **Step 5: Commit**

```bash
git add contracts/sources/lib/events.move
git commit -m "events: permissioned-pool events + auditor_ciphertext on deposit"
```

---

### Task 3: `lib/allowlist.move` — poseidon Merkle membership

**Files:**
- Create: `contracts/sources/lib/allowlist.move`
- Test: `contracts/tests/allowlist_tests.move`

- [ ] **Step 1: Write the failing test**

```move
#[test_only]
module utxopia::allowlist_tests {
    use utxopia::allowlist;
    use utxopia::commitment_tree;
    use sui::poseidon;

    // Build a 2-leaf tree: root = poseidon(leafA, leafB). Membership proof for
    // leafA: sibling = leafB, index_bits = 0 (leafA is the left child).
    #[test]
    fun verifies_valid_membership_and_rejects_tampered() {
        let leaf_a: u256 = 111;
        let leaf_b: u256 = 222;
        let root = poseidon::poseidon_bn254(&vector[leaf_a, leaf_b]);
        let root_be = commitment_tree::field_to_be_bytes(root);
        let sib_b = commitment_tree::field_to_be_bytes(leaf_b);

        // valid: leaf_a is left child (bit 0 = 0)
        assert!(allowlist::verify_membership(&root_be, leaf_a, &vector[sib_b], 0), 0);

        // wrong direction bit -> recomputes poseidon(sib, cur) -> different root
        assert!(!allowlist::verify_membership(&root_be, leaf_a, &vector[sib_b], 1), 1);

        // tampered sibling -> different root
        let bad_sib = commitment_tree::field_to_be_bytes(999);
        assert!(!allowlist::verify_membership(&root_be, leaf_a, &vector[bad_sib], 0), 2);

        // wrong leaf -> different root
        assert!(!allowlist::verify_membership(&root_be, 333, &vector[sib_b], 0), 3);
    }

    // Depth-2 tree: leaves [a,b,c,d]; prove leaf c (index 2 = bits 0b10).
    #[test]
    fun verifies_depth_two() {
        let a: u256 = 1; let b: u256 = 2; let c: u256 = 3; let d: u256 = 4;
        let ab = poseidon::poseidon_bn254(&vector[a, b]);
        let cd = poseidon::poseidon_bn254(&vector[c, d]);
        let root = poseidon::poseidon_bn254(&vector[ab, cd]);
        let root_be = commitment_tree::field_to_be_bytes(root);
        // c is left child at level 0 (sibling d), right child at level 1 (sibling ab)
        // index 2 -> bit0=0, bit1=1 -> index_bits = 0b10 = 2
        let siblings = vector[
            commitment_tree::field_to_be_bytes(d),
            commitment_tree::field_to_be_bytes(ab),
        ];
        assert!(allowlist::verify_membership(&root_be, c, &siblings, 2), 0);
        assert!(!allowlist::verify_membership(&root_be, c, &siblings, 0), 1);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sui move test allowlist`
Expected: FAIL — module `allowlist` does not exist / unbound function.

- [ ] **Step 3: Write the implementation**

```move
module utxopia::allowlist {
    /// poseidon Merkle membership proof verification for the permissioned-pool
    /// allowlist. Leaf = note public key field element. Internal nodes use the
    /// same `poseidon_bn254(left, right)` as the commitment tree, so the off-chain
    /// SDK builder and the Solana program can produce identical roots.
    use sui::poseidon;
    use utxopia::commitment_tree;

    /// Recompute the Merkle root from `leaf` upward using `siblings` (BE 32-byte
    /// field elements) and `index_bits` (bit i: 0 = current node is the LEFT child
    /// at level i, 1 = RIGHT child). Returns true iff it equals `root_be`.
    public fun verify_membership(
        root_be: &vector<u8>,
        leaf: u256,
        siblings: &vector<vector<u8>>,
        index_bits: u64,
    ): bool {
        let mut cur = leaf;
        let n = vector::length(siblings);
        let mut i = 0u64;
        while (i < n) {
            let sib = commitment_tree::field_from_be_bytes(vector::borrow(siblings, i));
            let bit = (index_bits >> (i as u8)) & 1;
            cur = if (bit == 0) {
                poseidon::poseidon_bn254(&vector[cur, sib])
            } else {
                poseidon::poseidon_bn254(&vector[sib, cur])
            };
            i = i + 1;
        };
        commitment_tree::field_from_be_bytes(root_be) == cur
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sui move test allowlist`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add contracts/sources/lib/allowlist.move contracts/tests/allowlist_tests.move
git commit -m "allowlist: poseidon Merkle membership verification"
```

---

### Task 4: `pool.move` — fields, AuditorCap, permissioned init, getters

**Files:**
- Modify: `contracts/sources/entry/pool.move`

- [ ] **Step 1: Add the four fields** to the `Pool` struct (after `btc_pool_script` line 44)

```move
        btc_pool_script: Option<vector<u8>>,
        permissioned: bool,
        allowlist_root: Option<vector<u8>>,
        auditor_frozen: bool,
        auditor_viewing_pubkey: Option<vector<u8>>,
```

- [ ] **Step 2: Add the AuditorCap struct** after `AdminCap` (line 18)

```move
    public struct AuditorCap has key {
        id: UID,
        pool_id: ID,
    }
```

- [ ] **Step 3: Refactor the pool constructor (DRY).** Replace the body of
`initialize` (lines 46-78) so the struct literal lives in a private `new_pool`
helper that both entry points share:

```move
    public fun initialize(tree_depth: u64, ctx: &mut TxContext) {
        assert!(tree_depth > 0, errors::invalid_tree_depth());
        let pool = new_pool(tree_depth, false, ctx);
        let pool_id = object::id(&pool);
        events::pool_created(object::id_to_address(&pool_id), tree_depth, PROTOCOL_VERSION);
        transfer::share_object(pool);
        transfer::transfer(AdminCap { id: object::new(ctx), pool_id }, tx_context::sender(ctx));
    }

    /// Create a permissioned pool and hand the AuditorCap to `auditor`. The pool
    /// also gets an AdminCap (to the sender) for protocol-parameter control; the
    /// two capabilities are independent and non-overlapping. The pool accepts NO
    /// deposits until the auditor calls `set_allowlist_root` (fail-closed).
    public fun initialize_permissioned(tree_depth: u64, auditor: address, ctx: &mut TxContext) {
        assert!(tree_depth > 0, errors::invalid_tree_depth());
        let pool = new_pool(tree_depth, true, ctx);
        let pool_id = object::id(&pool);
        let pool_addr = object::id_to_address(&pool_id);
        events::pool_created(pool_addr, tree_depth, PROTOCOL_VERSION);
        events::permissioned_pool_created(pool_addr, auditor);
        transfer::share_object(pool);
        transfer::transfer(AdminCap { id: object::new(ctx), pool_id }, tx_context::sender(ctx));
        transfer::transfer(AuditorCap { id: object::new(ctx), pool_id }, auditor);
    }

    fun new_pool(tree_depth: u64, permissioned: bool, ctx: &mut TxContext): Pool {
        Pool {
            id: object::new(ctx),
            tree_depth,
            paused: false,
            next_redemption_id: 0,
            min_deposit_sats: 0,
            max_deposit_sats: DEFAULT_MAX_DEPOSIT_SATS,
            deposit_fee_bps: 0,
            service_fee_sats: 0,
            pending_min_deposit_sats: option::none(),
            pending_max_deposit_sats: option::none(),
            pending_deposit_fee_bps: option::none(),
            pending_service_fee_sats: option::none(),
            pending_execute_after_ms: option::none(),
            btc_token_id: ZKBTC_TOKEN_ID,
            deposit_count: 0,
            total_shielded: 0,
            total_utxo_sats: 0,
            commitment_tree_id: option::none(),
            nullifier_registry_id: option::none(),
            btc_deposit_registry_id: option::none(),
            utxo_set_id: option::none(),
            vk_registry_id: option::none(),
            light_client_id: option::none(),
            token_registry_id: option::none(),
            btc_pool_script: option::none(),
            permissioned,
            allowlist_root: option::none(),
            auditor_frozen: false,
            auditor_viewing_pubkey: option::none(),
        }
    }
```

- [ ] **Step 4: Add `assert_auditor` + getters** (place near `assert_admin`, line 80)

```move
    public(package) fun assert_auditor(cap: &AuditorCap, pool: &Pool) {
        assert!(pool.permissioned, errors::not_permissioned());
        assert!(cap.pool_id == object::id(pool), errors::wrong_auditor_cap());
    }
    public fun is_permissioned(pool: &Pool): bool { pool.permissioned }
    public fun auditor_is_frozen(pool: &Pool): bool { pool.auditor_frozen }
    /// Aborts if the allowlist root has not been set yet (fail-closed).
    public(package) fun allowlist_root(pool: &Pool): vector<u8> {
        assert!(option::is_some(&pool.allowlist_root), errors::allowlist_root_unset());
        *option::borrow(&pool.allowlist_root)
    }
    public fun auditor_viewing_pubkey(pool: &Pool): Option<vector<u8>> { pool.auditor_viewing_pubkey }
```

- [ ] **Step 5: Build**

Run: `sui move build`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add contracts/sources/entry/pool.move
git commit -m "pool: permissioned fields, AuditorCap, initialize_permissioned, getters"
```

---

### Task 5: `pool.move` — auditor setters + authority tests

**Files:**
- Modify: `contracts/sources/entry/pool.move`
- Test: `contracts/tests/pool_admin_tests.move` (add tests)

- [ ] **Step 1: Write the failing tests** — append to `pool_admin_tests.move` (use its existing `SENDER`/scenario helpers; `AUDITOR` = `@0xAdD17`)

```move
    #[test]
    fun auditor_sets_root_freeze_and_viewing_key() {
        let mut scenario = test_scenario::begin(@0xA11CE);
        pool::initialize_permissioned(16, @0xAD17, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, @0xAD17);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let cap = test_scenario::take_from_sender<pool::AuditorCap>(&scenario);

        assert!(pool::is_permissioned(&pool), 0);
        pool::set_allowlist_root(&cap, &mut pool, b"01234567890123456789012345678901");
        pool::set_auditor_frozen(&cap, &mut pool, true);
        assert!(pool::auditor_is_frozen(&pool), 1);
        pool::set_auditor_viewing_pubkey(&cap, &mut pool, b"vk-bytes");
        assert!(option::is_some(&pool::auditor_viewing_pubkey(&pool)), 2);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    // AuditorCap from a different pool cannot control this one. abort 55 == wrong_auditor_cap.
    #[test, expected_failure(abort_code = 55)]
    fun rejects_foreign_auditor_cap() {
        let mut scenario = test_scenario::begin(@0xA11CE);
        pool::initialize_permissioned(16, @0xAD17, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, @0xAD17);
        pool::initialize_permissioned(16, @0xAD17, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, @0xAD17);

        // two pools + two auditor caps now exist; pair a cap with the other pool
        let mut pools = test_scenario::take_shared<Pool>(&scenario); // one of them
        let cap = test_scenario::take_from_sender<pool::AuditorCap>(&scenario);
        // take a second cap and the second pool, then cross them
        let cap2 = test_scenario::take_from_sender<pool::AuditorCap>(&scenario);
        // cap2 is bound to a different pool than `pools` for at least one pairing
        pool::set_auditor_frozen(&cap2, &mut pools, true); // expected to abort if mismatched

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_to_sender(&scenario, cap2);
        test_scenario::return_shared(pools);
        test_scenario::end(scenario);
    }

    // Calling an auditor function on a public (non-permissioned) pool aborts.
    // abort 56 == not_permissioned. (Public pool has no AuditorCap, so this test
    // mints one via a permissioned pool then targets the public pool.)
    #[test, expected_failure(abort_code = 56)]
    fun rejects_auditor_op_on_public_pool() {
        let mut scenario = test_scenario::begin(@0xA11CE);
        pool::initialize(16, test_scenario::ctx(&mut scenario));              // public
        test_scenario::next_tx(&mut scenario, @0xA11CE);
        pool::initialize_permissioned(16, @0xAD17, test_scenario::ctx(&mut scenario)); // perm
        test_scenario::next_tx(&mut scenario, @0xAD17);

        // take the PUBLIC pool (permissioned == false) and the AuditorCap
        let mut public_pool = test_scenario::take_shared<Pool>(&scenario);
        assert!(!pool::is_permissioned(&public_pool), 99);
        let cap = test_scenario::take_from_sender<pool::AuditorCap>(&scenario);
        pool::set_allowlist_root(&cap, &mut public_pool, b"01234567890123456789012345678901");

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(public_pool);
        test_scenario::end(scenario);
    }
```

Note for the implementer: `take_shared<Pool>` returns one of the shared pools
nondeterministically when several exist. If `rejects_foreign_auditor_cap` /
`rejects_auditor_op_on_public_pool` flake on which pool is returned, assert the
pool's `is_permissioned` flag and re-take until you have the intended one, or
capture object IDs at creation via `test_scenario::most_recent_id_for_address`.
Keep the abort-code expectation as specified.

- [ ] **Step 2: Run tests to verify they fail**

Run: `sui move test auditor_sets_root`
Expected: FAIL — `set_allowlist_root` unbound.

- [ ] **Step 3: Implement the setters** in `pool.move` (place after `set_btc_pool_script`)

```move
    public fun set_allowlist_root(cap: &AuditorCap, pool: &mut Pool, root: vector<u8>) {
        assert_auditor(cap, pool);
        assert!(vector::length(&root) == 32, errors::invalid_commitment());
        pool.allowlist_root = option::some(root);
        events::allowlist_root_updated(object::uid_to_address(&pool.id), root);
    }
    public fun set_auditor_frozen(cap: &AuditorCap, pool: &mut Pool, frozen: bool) {
        assert_auditor(cap, pool);
        pool.auditor_frozen = frozen;
        events::auditor_frozen(object::uid_to_address(&pool.id), frozen);
    }
    public fun set_auditor_viewing_pubkey(cap: &AuditorCap, pool: &mut Pool, pubkey: vector<u8>) {
        assert_auditor(cap, pool);
        pool.auditor_viewing_pubkey = option::some(pubkey);
        events::auditor_viewing_pubkey_updated(object::uid_to_address(&pool.id), pubkey);
    }
```

Also add `use utxopia::pool::AuditorCap;`-style visibility: `AuditorCap` is
defined in this module, so no import needed. Ensure `pool_admin_tests.move`
imports it via `use utxopia::pool::{Self, Pool, AdminCap, AuditorCap};` (extend
the existing `use`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `sui move test` (run the three new tests; also full suite)
Expected: the three new tests PASS; full suite still green.

- [ ] **Step 5: Commit**

```bash
git add contracts/sources/entry/pool.move contracts/tests/pool_admin_tests.move
git commit -m "pool: auditor setters (allowlist root / freeze / viewing key) + tests"
```

---

### Task 6: `pool.move` — auditor-gated rotation

**Files:**
- Modify: `contracts/sources/entry/pool.move`
- Test: `contracts/tests/pool_admin_tests.move`

Read the existing `rotate_commitment_tree(cap: &AdminCap, ...)` (around line 175)
to copy its guards exactly.

- [ ] **Step 1: Write the failing test** — append to `pool_admin_tests.move`,
mirroring the existing `rotate_commitment_tree_rebinds_to_successor` test but
creating the pool with `initialize_permissioned` and rotating with the
`AuditorCap` via `rotate_commitment_tree_permissioned`. (Copy the body of the
existing admin-rotate test; swap `initialize`→`initialize_permissioned(…, @0xAD17, …)`,
take `AuditorCap` instead of `AdminCap`, and call the new function.)

- [ ] **Step 2: Run to verify it fails**

Run: `sui move test rotate_commitment_tree_permissioned`
Expected: FAIL — function unbound.

- [ ] **Step 3: Implement** — add a permissioned rotate that reuses the same
guard logic as the admin version, gated by `assert_auditor`:

```move
    public fun rotate_commitment_tree_permissioned(
        cap: &AuditorCap,
        pool: &mut Pool,
        old_tree: &CommitmentTree,
        new_tree: &CommitmentTree,
    ) {
        assert_auditor(cap, pool);
        rotate_commitment_tree_inner(pool, old_tree, new_tree);
    }
```

Refactor the existing `rotate_commitment_tree(cap: &AdminCap, ...)` so its guard
body (the asserts + rebind + `events::commitment_tree_rotated(...)`) lives in a
private `fun rotate_commitment_tree_inner(pool, old_tree, new_tree)`, and the
admin entry calls `assert_admin(cap, pool); rotate_commitment_tree_inner(...)`.
This keeps a single source of truth for the rotation guards.

- [ ] **Step 4: Run to verify it passes**

Run: `sui move test rotate`
Expected: both admin and permissioned rotation tests PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/sources/entry/pool.move contracts/tests/pool_admin_tests.move
git commit -m "pool: auditor-gated commitment-tree rotation"
```

---

### Task 7: `btc_deposit.move` — allowlist enforcement at deposit

**Files:**
- Modify: `contracts/sources/entry/btc_deposit.move`
- Test: `contracts/tests/btc_deposit_tests.move`

- [ ] **Step 1: Write the failing test** — add to `btc_deposit_tests.move`. Build
on the existing `completes_deposit_once` setup, but create the pool with
`pool::initialize_permissioned`, set an allowlist root over the deposit's
`note_public_key`, and pass a valid membership proof. Then a sibling test with a
non-member key expecting abort 53 (`not_allowlisted`), and one with
`set_auditor_frozen(true)` expecting abort 54 (`auditor_frozen`).

Skeleton (fill the existing-test scaffolding for inclusion/op_return):

```move
    #[test]
    fun permissioned_deposit_with_valid_proof_succeeds() {
        // ... existing setup up to having `note_public_key` (npk) bytes ...
        // single-leaf allowlist: root = npk_field
        let npk_field = commitment_tree::field_from_be_bytes(&npk);
        let root = commitment_tree::field_to_be_bytes(npk_field);
        // auditor sets root; membership proof for a 1-leaf tree is empty
        pool::set_allowlist_root(&auditor_cap, &mut pool, root);
        btc_deposit::complete_deposit(
            &mut pool, &mut registry, &mut utxo_set, &mut tree, inclusion,
            sweep_raw_tx, deposit_raw_tx, /*direct_to_pool*/ false,
            /*allowlist_siblings*/ vector[], /*allowlist_index_bits*/ 0,
            /*auditor_ciphertext*/ b"ct",
            test_scenario::ctx(&mut scenario),
        );
        // assert a leaf was inserted (existing helper)
    }
```

(For a 1-leaf allowlist the root IS the leaf, so `verify_membership(root, npk_field, [], 0)` returns `field_from_be_bytes(root) == npk_field` = true. Use this to avoid building a multi-level proof in-test.)

- [ ] **Step 2: Run to verify it fails**

Run: `sui move test permissioned_deposit`
Expected: FAIL — `complete_deposit` arity mismatch (new params not yet added).

- [ ] **Step 3: Implement** — change `complete_deposit`'s signature to accept the
proof + ciphertext, and enforce after `note_public_key` is known (the
`find_deposit_op_return` result, currently around line 69) and before/at the
commitment insert. Add params (after `direct_to_pool: bool`):

```move
        direct_to_pool: bool,
        allowlist_siblings: vector<vector<u8>>,
        allowlist_index_bits: u64,
        auditor_ciphertext: vector<u8>,
        ctx: &mut TxContext,
```

Insert enforcement right after the `note_public_key` is parsed (after the
`assert!(pool_tag == ...)` line) :

```move
        if (pool::is_permissioned(pool)) {
            assert!(!pool::auditor_is_frozen(pool), errors::auditor_frozen());
            let npk_field = commitment_tree::field_from_be_bytes(&note_public_key);
            let root = pool::allowlist_root(pool); // aborts if unset (fail-closed)
            assert!(
                allowlist::verify_membership(&root, npk_field, &allowlist_siblings, allowlist_index_bits),
                errors::not_allowlisted(),
            );
        };
```

Add `use utxopia::allowlist;` to the module imports.

Then make the deposit-event change **in this same commit** (so the struct, emit
fn, and caller all change together and the build stays green):
1. In `events.move`, add a trailing `auditor_ciphertext: vector<u8>` field to the
   `BtcDepositVerified` struct, and a trailing `auditor_ciphertext: vector<u8>`
   parameter to the `btc_deposit_verified` emit fn, threading it into the struct.
2. In `complete_deposit`, pass `auditor_ciphertext` as the new trailing arg to
   `events::btc_deposit_verified(...)`. For public pools the enforcement branch is
   skipped and `auditor_ciphertext` is simply emitted (caller may pass `vector[]`).

- [ ] **Step 4: Run to verify it passes**

Run: `sui move test btc_deposit`
Expected: all `btc_deposit` tests PASS (existing `completes_deposit_once` etc.
must be updated to pass the three new args — for public-pool tests:
`vector[], 0, vector[]`).

- [ ] **Step 5: Commit**

```bash
git add contracts/sources/entry/btc_deposit.move contracts/sources/lib/events.move contracts/tests/btc_deposit_tests.move
git commit -m "btc_deposit: enforce allowlist membership on permissioned deposits"
```

---

### Task 8: `token_registry.move` — allowlist enforcement at shield

**Files:**
- Modify: `contracts/sources/entry/token_registry.move`
- Test: `contracts/tests/token_registry_tests.move`

- [ ] **Step 1: Write the failing test** — add to `token_registry_tests.move`,
mirroring the existing `shield_commitment_value_and_fee_and_announcement` test
but with `pool::initialize_permissioned`, an allowlist root over the shield's
`npk`, and a valid (1-leaf) proof; plus a non-member abort-53 test and a
frozen abort-54 test. Use the same 1-leaf trick: `root = field_to_be_bytes(npk_field)`,
proof `vector[]`, bits `0`.

- [ ] **Step 2: Run to verify it fails**

Run: `sui move test shield`
Expected: FAIL — `shield` arity mismatch.

- [ ] **Step 3: Implement** — add params to `shield<T>` (after the existing args,
before `ctx`):

```move
        allowlist_siblings: vector<vector<u8>>,
        allowlist_index_bits: u64,
        auditor_ciphertext: vector<u8>,
        ctx: &mut TxContext,
```

Insert enforcement right after `npk_field` is computed (line 102 area), before
the commitment insert:

```move
        if (pool::is_permissioned(pool)) {
            assert!(!pool::auditor_is_frozen(pool), errors::auditor_frozen());
            let root = pool::allowlist_root(pool);
            assert!(
                allowlist::verify_membership(&root, npk_field, &allowlist_siblings, allowlist_index_bits),
                errors::not_allowlisted(),
            );
        };
```

Add `use utxopia::allowlist;`. If the shield event should carry the auditor
ciphertext, thread it into the shield event emit (mirror the deposit change); if
the shield event struct doesn't exist or shouldn't change, emit a standalone
`events::` line or drop `auditor_ciphertext` from shield — decide by reading the
current shield event. Keep the parameter so the SDK can supply it uniformly.

- [ ] **Step 4: Run to verify it passes**

Run: `sui move test` (full suite)
Expected: all PASS — including updated existing `shield_*` tests (public-pool
calls pass `vector[], 0, vector[]`).

- [ ] **Step 5: Commit**

```bash
git add contracts/sources/entry/token_registry.move contracts/tests/token_registry_tests.move
git commit -m "token_registry: enforce allowlist membership on permissioned shields"
```

---

### Task 9: Full-suite regression + spec sync

**Files:**
- Modify: `docs/security-fixes.md` (optional cross-ref)

- [ ] **Step 1: Run the full suite**

Run: `sui move test`
Expected: all tests PASS (including pre-existing public-pool tests, proving public
pools are unaffected).

- [ ] **Step 2: Confirm public-pool regression explicitly** — verify at least one
untouched public-pool deposit/shield/transact test still passes unchanged in
behavior (it does if the suite is green and those tests pass `vector[], 0, vector[]`).

- [ ] **Step 3: Commit any doc cross-reference**

```bash
git add docs/security-fixes.md
git commit -m "docs: note permissioned-pool feature landed"
```

---

## Notes for the implementer

- Adding params to `complete_deposit` / `shield` is an **upgrade-incompatible**
  public-signature change → the deployment uses a fresh package + re-init, per the
  procedure in `docs/security-fixes.md`. Do NOT attempt an in-place `sui client upgrade`.
- `allowlist_root` is fail-closed: a permissioned pool rejects all deposits until
  the auditor sets it.
- The `auditor_ciphertext` is stored/emitted, never verified on-chain.
- The SDK (allowlist tree builder + adapter proof wiring) and the Solana parity
  implementation are separate plans; this plan leaves `complete_deposit`/`shield`
  callable with empty proof args for public pools so the SDK can adopt incrementally.
