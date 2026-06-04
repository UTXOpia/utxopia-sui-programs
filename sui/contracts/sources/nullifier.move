module utxopia::nullifier {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};

    public struct NullifierRegistry has key {
        id: UID,
        spent: vector<vector<u8>>,
    }

    public fun initialize_registry(ctx: &mut TxContext) {
        let registry = NullifierRegistry {
            id: object::new(ctx),
            spent: vector[],
        };
        transfer::share_object(registry);
    }

    public fun spend(pool: &Pool, registry: &mut NullifierRegistry, nullifier: vector<u8>) {
        pool::assert_not_paused(pool);
        record_spend(pool::pool_id(pool), registry, nullifier);
    }

    public(package) fun record_spend(pool_id: address, registry: &mut NullifierRegistry, nullifier: vector<u8>) {
        assert!(!contains(registry, &nullifier), errors::nullifier_spent());
        vector::push_back(&mut registry.spent, nullifier);
        events::nullifier_spent(pool_id, *vector::borrow(&registry.spent, vector::length(&registry.spent) - 1));
    }

    public fun contains(registry: &NullifierRegistry, nullifier: &vector<u8>): bool {
        let mut i = 0;
        let len = vector::length(&registry.spent);
        while (i < len) {
            if (vector::borrow(&registry.spent, i) == nullifier) {
                return true
            };
            i = i + 1;
        };
        false
    }
}
