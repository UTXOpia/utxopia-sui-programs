module utxopia::pool {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use utxopia::errors;
    use utxopia::events;

    const PROTOCOL_VERSION: u64 = 1;

    public struct AdminCap has key {
        id: UID,
    }

    /// Pool state. The Merkle root and leaf count now live in `commitment_tree`
    /// (the single source of truth); `Pool` only holds policy/admin state.
    public struct Pool has key {
        id: UID,
        tree_depth: u64,
        paused: bool,
        next_redemption_id: u64,
    }

    public fun initialize(tree_depth: u64, ctx: &mut TxContext) {
        assert!(tree_depth > 0, errors::invalid_tree_depth());

        let pool = Pool {
            id: object::new(ctx),
            tree_depth,
            paused: false,
            next_redemption_id: 0,
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

    public fun tree_depth(pool: &Pool): u64 {
        pool.tree_depth
    }

    public fun paused(pool: &Pool): bool {
        pool.paused
    }
}
