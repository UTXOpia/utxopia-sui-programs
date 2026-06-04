module utxopia::pool {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use utxopia::errors;
    use utxopia::events;

    const PROTOCOL_VERSION: u64 = 1;
    const FIELD_BYTES_LEN: u64 = 32;

    public struct AdminCap has key {
        id: UID,
    }

    public struct Pool has key {
        id: UID,
        tree_depth: u64,
        paused: bool,
        latest_root: vector<u8>,
        latest_root_index: u64,
        next_leaf_index: u64,
        next_redemption_id: u64,
    }

    public fun initialize(tree_depth: u64, initial_root: vector<u8>, ctx: &mut TxContext) {
        assert!(tree_depth > 0, errors::invalid_tree_depth());
        assert!(vector::length(&initial_root) == FIELD_BYTES_LEN, errors::invalid_commitment());

        let pool = Pool {
            id: object::new(ctx),
            tree_depth,
            paused: false,
            latest_root: initial_root,
            latest_root_index: 0,
            next_leaf_index: 0,
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

    public(package) fun next_leaf_index(pool: &Pool): u64 {
        pool.next_leaf_index
    }

    public(package) fun increment_leaf_index(pool: &mut Pool) {
        pool.next_leaf_index = pool.next_leaf_index + 1;
    }

    public(package) fun set_latest_root(pool: &mut Pool, root: vector<u8>) {
        pool.latest_root_index = pool.latest_root_index + 1;
        pool.latest_root = root;
        events::merkle_root_updated(pool_id(pool), pool.latest_root_index, pool.latest_root);
    }

    public(package) fun allocate_redemption_id(pool: &mut Pool): u64 {
        let redemption_id = pool.next_redemption_id;
        pool.next_redemption_id = redemption_id + 1;
        redemption_id
    }

    public fun latest_root(pool: &Pool): vector<u8> {
        pool.latest_root
    }

    public fun latest_root_index(pool: &Pool): u64 {
        pool.latest_root_index
    }

    public fun tree_depth(pool: &Pool): u64 {
        pool.tree_depth
    }

    public fun paused(pool: &Pool): bool {
        pool.paused
    }
}
