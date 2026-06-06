module utxopia::pool {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use std::option::{Self, Option};
    use utxopia::errors;
    use utxopia::events;

    const PROTOCOL_VERSION: u64 = 1;
    const ZKBTC_TOKEN_ID: u256 = 0x7a627463; // "zkbtc"
    const DEFAULT_MAX_DEPOSIT_SATS: u64 = 2_100_000_000_000_000; // 21M BTC
    const MAX_BPS: u16 = 10_000;
    const CONFIG_TIMELOCK_DELAY_MS: u64 = 172_800_000; // 48h, matching Solana TIMELOCK_DELAY_SECS

    /// Authority over exactly one Pool (bound by `pool_id`). Minting a cap via `initialize`
    /// only grants authority over the pool it created — never another pool.
    public struct AdminCap has key {
        id: UID,
        pool_id: ID,
    }

    /// Pool state. The Merkle root and leaf count live in `commitment_tree`; `Pool` holds
    /// policy/admin/accounting state and pins the canonical companion object ids so callers
    /// of `transact`/`complete_deposit` cannot substitute a fresh tree/registry.
    public struct Pool has key {
        id: UID,
        tree_depth: u64,
        paused: bool,
        next_redemption_id: u64,
        // deposit policy
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
        // accounting
        deposit_count: u64,
        total_shielded: u128,
        total_utxo_sats: u128,
        // canonical companion object ids (set once via AdminCap)
        commitment_tree_id: Option<ID>,
        nullifier_registry_id: Option<ID>,
        btc_deposit_registry_id: Option<ID>,
        utxo_set_id: Option<ID>,
        vk_registry_id: Option<ID>,
        light_client_id: Option<ID>,
        btc_pool_script: Option<vector<u8>>,
    }

    public fun initialize(tree_depth: u64, ctx: &mut TxContext) {
        assert!(tree_depth > 0, errors::invalid_tree_depth());

        let pool = Pool {
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
            btc_pool_script: option::none(),
        };
        let pool_id = object::id(&pool);
        events::pool_created(object::id_to_address(&pool_id), tree_depth, PROTOCOL_VERSION);

        transfer::share_object(pool);
        transfer::transfer(AdminCap { id: object::new(ctx), pool_id }, tx_context::sender(ctx));
    }

    public(package) fun assert_admin(cap: &AdminCap, pool: &Pool) {
        assert!(cap.pool_id == object::id(pool), errors::wrong_cap());
    }

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
        assert!(deposit_fee_bps <= MAX_BPS, errors::invalid_btc_deposit());
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

    // --- canonical companion binding (AdminCap-gated, set once each) ---
    // Set-once is enforced: re-binding aborts. Swapping in a fresh companion
    // (e.g. an empty NullifierRegistry) would reset spent state and re-enable
    // double-spends, so the binding is immutable after initial pinning.

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
    public fun set_btc_pool_script(cap: &AdminCap, pool: &mut Pool, script: vector<u8>) {
        assert_admin(cap, pool);
        assert!(option::is_none(&pool.btc_pool_script), errors::already_bound());
        assert!(vector::length(&script) > 0, errors::invalid_btc_deposit());
        pool.btc_pool_script = option::some(script);
    }

    // --- canonical-object assertions (fail closed: unbound OR mismatch both abort) ---

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
