module utxopia::pool {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use std::option::{Self, Option};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    const PROTOCOL_VERSION: u64 = 1;
    const ZKBTC_TOKEN_ID: u256 = 0x7a627463;
    const DEFAULT_MAX_DEPOSIT_SATS: u64 = 2_100_000_000_000_000;
    const MAX_BPS: u16 = 10_000;
    const CONFIG_TIMELOCK_DELAY_MS: u64 = 172_800_000;
    public struct AdminCap has key {
        id: UID,
        pool_id: ID,
    }
    public struct AuditorCap has key {
        id: UID,
        pool_id: ID,
    }
    public struct Pool has key {
        id: UID,
        tree_depth: u64,
        paused: bool,
        next_redemption_id: u64,
        min_deposit_sats: u64,
        max_deposit_sats: u64,
        deposit_fee_bps: u16,
        service_fee_sats: u64,
        pending_min_deposit_sats: Option<u64>,
        pending_max_deposit_sats: Option<u64>,
        pending_deposit_fee_bps: Option<u16>,
        pending_service_fee_sats: Option<u64>,
        pending_execute_after_ms: Option<u64>,
        btc_token_id: u256,
        deposit_count: u64,
        total_shielded: u128,
        total_utxo_sats: u128,
        commitment_tree_id: Option<ID>,
        nullifier_registry_id: Option<ID>,
        btc_deposit_registry_id: Option<ID>,
        utxo_set_id: Option<ID>,
        vk_registry_id: Option<ID>,
        light_client_id: Option<ID>,
        token_registry_id: Option<ID>,
        btc_pool_script: Option<vector<u8>>,
        permissioned: bool,
        auditor_frozen: bool,
        auditor_viewing_pubkey: Option<vector<u8>>,
    }
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
    /// two capabilities are independent and non-overlapping. Deposits require the
    /// auditor co-signature via AuditorCap (fail-closed).
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
            auditor_frozen: false,
            auditor_viewing_pubkey: option::none(),
        }
    }

    public(package) fun assert_admin(cap: &AdminCap, pool: &Pool) {
        assert!(cap.pool_id == object::id(pool), errors::wrong_cap());
    }
    public(package) fun assert_auditor(cap: &AuditorCap, pool: &Pool) {
        assert!(pool.permissioned, errors::not_permissioned());
        assert!(cap.pool_id == object::id(pool), errors::wrong_auditor_cap());
    }
    public fun is_permissioned(pool: &Pool): bool { pool.permissioned }
    public fun auditor_is_frozen(pool: &Pool): bool { pool.auditor_frozen }
    public fun auditor_viewing_pubkey(pool: &Pool): Option<vector<u8>> { pool.auditor_viewing_pubkey }
    public fun set_paused(cap: &AdminCap, pool: &mut Pool, paused: bool) {
        assert_admin(cap, pool);
        pool.paused = paused;
        events::pool_paused(object::uid_to_address(&pool.id), paused);
    }
    public fun propose_deposit_config_update(
        cap: &AdminCap,
        pool: &mut Pool,
        min_deposit_sats: u64,
        max_deposit_sats: u64,
        deposit_fee_bps: u16,
        service_fee_sats: u64,
        clock: &Clock,
    ) {
        assert_admin(cap, pool);
        // Strict `<`: deposit_fee_bps == MAX_BPS (100%) makes total_fee >= amount_sats,
        // so the downstream `amount_sats > total_fee` check can never pass -> global deposit DoS.
        assert!(deposit_fee_bps < MAX_BPS, errors::invalid_btc_deposit());
        assert!(min_deposit_sats <= max_deposit_sats, errors::invalid_btc_deposit());
        let execute_after = clock::timestamp_ms(clock) + CONFIG_TIMELOCK_DELAY_MS;
        pool.pending_min_deposit_sats = option::some(min_deposit_sats);
        pool.pending_max_deposit_sats = option::some(max_deposit_sats);
        pool.pending_deposit_fee_bps = option::some(deposit_fee_bps);
        pool.pending_service_fee_sats = option::some(service_fee_sats);
        pool.pending_execute_after_ms = option::some(execute_after);
    }
    public fun execute_deposit_config_update(pool: &mut Pool, clock: &Clock) {
        assert!(option::is_some(&pool.pending_execute_after_ms), errors::no_pending_proposal());
        assert!(clock::timestamp_ms(clock) >= *option::borrow(&pool.pending_execute_after_ms), errors::timelock_not_elapsed());
        pool.min_deposit_sats = *option::borrow(&pool.pending_min_deposit_sats);
        pool.max_deposit_sats = *option::borrow(&pool.pending_max_deposit_sats);
        pool.deposit_fee_bps = *option::borrow(&pool.pending_deposit_fee_bps);
        pool.service_fee_sats = *option::borrow(&pool.pending_service_fee_sats);
        clear_pending_deposit_config(pool);
    }
    public fun cancel_deposit_config_update(cap: &AdminCap, pool: &mut Pool) {
        assert_admin(cap, pool);
        assert!(option::is_some(&pool.pending_execute_after_ms), errors::no_pending_proposal());
        clear_pending_deposit_config(pool);
    }
    fun clear_pending_deposit_config(pool: &mut Pool) {
        pool.pending_min_deposit_sats = option::none();
        pool.pending_max_deposit_sats = option::none();
        pool.pending_deposit_fee_bps = option::none();
        pool.pending_service_fee_sats = option::none();
        pool.pending_execute_after_ms = option::none();
    }
    public fun set_commitment_tree_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.commitment_tree_id), errors::already_bound());
        pool.commitment_tree_id = option::some(id);
    }
    public fun set_nullifier_registry_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.nullifier_registry_id), errors::already_bound());
        pool.nullifier_registry_id = option::some(id);
    }
    public fun set_btc_deposit_registry_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.btc_deposit_registry_id), errors::already_bound());
        pool.btc_deposit_registry_id = option::some(id);
    }
    public fun set_utxo_set_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.utxo_set_id), errors::already_bound());
        pool.utxo_set_id = option::some(id);
    }
    public fun set_vk_registry_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.vk_registry_id), errors::already_bound());
        pool.vk_registry_id = option::some(id);
    }
    public fun set_light_client_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.light_client_id), errors::already_bound());
        pool.light_client_id = option::some(id);
    }
    public fun set_token_registry_id(cap: &AdminCap, pool: &mut Pool, id: ID) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.token_registry_id), errors::already_bound());
        pool.token_registry_id = option::some(id);
    }
    public fun set_btc_pool_script(cap: &AdminCap, pool: &mut Pool, script: vector<u8>) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.btc_pool_script), errors::already_bound());
        assert!(vector::length(&script) > 0, errors::invalid_btc_deposit());
        pool.btc_pool_script = option::some(script);
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
    /// Rebind the pool from a full commitment tree to a fresh successor (minted via
    /// `commitment_tree::create_successor`). This is the rotation path that lets the pool
    /// keep accepting new notes past a single tree's 65,536-leaf capacity. Guarded so it
    /// can only ever advance to an empty, correctly-numbered successor of the bound tree.
    public fun rotate_commitment_tree(
        cap: &AdminCap,
        pool: &mut Pool,
        old_tree: &CommitmentTree,
        new_tree: &CommitmentTree,
    ) {
        assert_admin(cap, pool);
        rotate_commitment_tree_inner(pool, old_tree, new_tree);
    }

    /// Auditor-gated variant of commitment tree rotation. Performs the identical rotation
    /// logic as the admin version but gated by `assert_auditor` (requires a permissioned pool).
    public fun rotate_commitment_tree_permissioned(
        cap: &AuditorCap,
        pool: &mut Pool,
        old_tree: &CommitmentTree,
        new_tree: &CommitmentTree,
    ) {
        assert_auditor(cap, pool);
        rotate_commitment_tree_inner(pool, old_tree, new_tree);
    }

    /// Shared rotation logic: validates old_tree is bound and full, validates new_tree is the
    /// immediate empty successor, then rebinds the pool and emits the rotation event.
    fun rotate_commitment_tree_inner(
        pool: &mut Pool,
        old_tree: &CommitmentTree,
        new_tree: &CommitmentTree,
    ) {
        // old_tree must be the tree currently bound to this pool, and it must be full.
        assert_commitment_tree(pool, object::id(old_tree));
        assert!(commitment_tree::is_full(old_tree), errors::tree_not_full());
        // new_tree must be the immediate, empty successor of old_tree.
        assert!(
            commitment_tree::tree_number(new_tree) == commitment_tree::tree_number(old_tree) + 1,
            errors::invalid_tree_rotation(),
        );
        assert!(commitment_tree::next_index(new_tree) == 0, errors::invalid_tree_rotation());
        pool.commitment_tree_id = option::some(object::id(new_tree));
        events::commitment_tree_rotated(
            pool_id(pool),
            commitment_tree::id(old_tree),
            commitment_tree::id(new_tree),
            commitment_tree::tree_number(new_tree),
        );
    }
    public(package) fun assert_commitment_tree(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.commitment_tree_id, &id), errors::wrong_object());
    }
    public(package) fun assert_nullifier_registry(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.nullifier_registry_id, &id), errors::wrong_object());
    }
    public(package) fun assert_btc_deposit_registry(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.btc_deposit_registry_id, &id), errors::wrong_object());
    }
    public(package) fun assert_utxo_set(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.utxo_set_id, &id), errors::wrong_object());
    }
    public(package) fun assert_vk_registry(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.vk_registry_id, &id), errors::wrong_object());
    }
    public(package) fun assert_light_client(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.light_client_id, &id), errors::wrong_object());
    }
    public(package) fun assert_token_registry(pool: &Pool, id: ID) {
        assert!(option::contains(&pool.token_registry_id, &id), errors::wrong_object());
    }
    public fun assert_not_paused(pool: &Pool) {
        assert!(!pool.paused, errors::pool_paused());
    }
    public(package) fun btc_pool_script(pool: &Pool): vector<u8> {
        assert!(option::is_some(&pool.btc_pool_script), errors::wrong_object());
        *option::borrow(&pool.btc_pool_script)
    }
    public(package) fun pool_id(pool: &Pool): address {
        object::uid_to_address(&pool.id)
    }
    public(package) fun allocate_redemption_id(pool: &mut Pool): u64 {
        let redemption_id = pool.next_redemption_id;
        pool.next_redemption_id = redemption_id + 1;
        redemption_id
    }
    public(package) fun record_deposit(pool: &mut Pool, shielded_sats: u64, gross_sats: u64) {
        pool.deposit_count = pool.deposit_count + 1;
        pool.total_shielded = pool.total_shielded + (shielded_sats as u128);
        pool.total_utxo_sats = pool.total_utxo_sats + (gross_sats as u128);
    }
    public(package) fun record_redemption_request(pool: &mut Pool, amount_sats: u128) {
        assert!(pool.total_shielded >= amount_sats, errors::invalid_redemption());
        pool.total_shielded = pool.total_shielded - amount_sats;
    }
    public fun tree_depth(pool: &Pool): u64 { pool.tree_depth }
    public fun paused(pool: &Pool): bool { pool.paused }
    public fun min_deposit_sats(pool: &Pool): u64 { pool.min_deposit_sats }
    public fun max_deposit_sats(pool: &Pool): u64 { pool.max_deposit_sats }
    public fun deposit_fee_bps(pool: &Pool): u16 { pool.deposit_fee_bps }
    public fun service_fee_sats(pool: &Pool): u64 { pool.service_fee_sats }
    public fun pending_execute_after_ms(pool: &Pool): Option<u64> { pool.pending_execute_after_ms }
    public fun btc_token_id(pool: &Pool): u256 { pool.btc_token_id }
    public fun deposit_count(pool: &Pool): u64 { pool.deposit_count }
    public fun total_shielded(pool: &Pool): u128 { pool.total_shielded }
    public fun total_utxo_sats(pool: &Pool): u128 { pool.total_utxo_sats }
}
