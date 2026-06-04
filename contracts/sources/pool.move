module utxopia::pool {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use utxopia::errors;
    use utxopia::events;

    const PROTOCOL_VERSION: u64 = 1;
    const ZKBTC_TOKEN_ID: u256 = 0x7a627463; // "zkbtc"
    const DEFAULT_MAX_DEPOSIT_SATS: u64 = 2_100_000_000_000_000; // 21M BTC
    const MAX_BPS: u16 = 10_000;

    public struct AdminCap has key {
        id: UID,
    }

    /// Pool state. The Merkle root and leaf count live in `commitment_tree`
    /// (the single source of truth); `Pool` holds policy/admin/accounting state.
    public struct Pool has key {
        id: UID,
        tree_depth: u64,
        paused: bool,
        next_redemption_id: u64,
        // deposit policy
        min_deposit_sats: u64,
        max_deposit_sats: u64,
        deposit_fee_bps: u16,    // protocol fee, <= 10_000
        service_fee_sats: u64,   // flat per-deposit service fee
        btc_token_id: u256,      // = ZKBTC_TOKEN_ID
        // accounting
        deposit_count: u64,
        total_shielded: u128,
        total_utxo_sats: u128,
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
            btc_token_id: ZKBTC_TOKEN_ID,
            deposit_count: 0,
            total_shielded: 0,
            total_utxo_sats: 0,
        };
        let pool_id = object::uid_to_address(&pool.id);

        let admin_cap = AdminCap { id: object::new(ctx) };
        events::pool_created(pool_id, tree_depth, PROTOCOL_VERSION);

        transfer::share_object(pool);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun set_paused(_: &AdminCap, pool: &mut Pool, paused: bool) {
        pool.paused = paused;
        events::pool_paused(object::uid_to_address(&pool.id), paused);
    }

    /// Configure deposit policy (AdminCap-gated). Fees are bounded; min <= max enforced.
    public fun set_deposit_config(
        _: &AdminCap,
        pool: &mut Pool,
        min_deposit_sats: u64,
        max_deposit_sats: u64,
        deposit_fee_bps: u16,
        service_fee_sats: u64,
    ) {
        assert!(deposit_fee_bps <= MAX_BPS, errors::invalid_btc_deposit());
        assert!(min_deposit_sats <= max_deposit_sats, errors::invalid_btc_deposit());
        pool.min_deposit_sats = min_deposit_sats;
        pool.max_deposit_sats = max_deposit_sats;
        pool.deposit_fee_bps = deposit_fee_bps;
        pool.service_fee_sats = service_fee_sats;
    }

    public fun assert_not_paused(pool: &Pool) {
        assert!(!pool.paused, errors::pool_paused());
    }

    public(package) fun pool_id(pool: &Pool): address {
        object::uid_to_address(&pool.id)
    }

    public(package) fun allocate_redemption_id(pool: &mut Pool): u64 {
        let redemption_id = pool.next_redemption_id;
        pool.next_redemption_id = redemption_id + 1;
        redemption_id
    }

    /// Record a completed deposit's accounting (package-only; called by btc_deposit).
    public(package) fun record_deposit(pool: &mut Pool, shielded_sats: u64, gross_sats: u64) {
        pool.deposit_count = pool.deposit_count + 1;
        pool.total_shielded = pool.total_shielded + (shielded_sats as u128);
        pool.total_utxo_sats = pool.total_utxo_sats + (gross_sats as u128);
    }

    public fun tree_depth(pool: &Pool): u64 { pool.tree_depth }
    public fun paused(pool: &Pool): bool { pool.paused }
    public fun min_deposit_sats(pool: &Pool): u64 { pool.min_deposit_sats }
    public fun max_deposit_sats(pool: &Pool): u64 { pool.max_deposit_sats }
    public fun deposit_fee_bps(pool: &Pool): u16 { pool.deposit_fee_bps }
    public fun service_fee_sats(pool: &Pool): u64 { pool.service_fee_sats }
    public fun btc_token_id(pool: &Pool): u256 { pool.btc_token_id }
    public fun deposit_count(pool: &Pool): u64 { pool.deposit_count }
    public fun total_shielded(pool: &Pool): u128 { pool.total_shielded }
    public fun total_utxo_sats(pool: &Pool): u128 { pool.total_utxo_sats }
}
