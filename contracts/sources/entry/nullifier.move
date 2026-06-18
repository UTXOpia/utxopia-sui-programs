module utxopia::nullifier {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::tx_context::TxContext;
    use utxopia::errors;
    use utxopia::events;
    /// Spent-nullifier set. Backed by a `Table` (dynamic-field storage) rather than an
    /// inline `vector` so the shared object never approaches Sui's object-size ceiling as
    /// the set grows, and membership is an O(1) lookup instead of an O(n) scan
    /// (audit MEDIUM #12: unbounded nullifier vector growth + linear-scan DoS).
    public struct NullifierRegistry has key {
        id: UID,
        spent: Table<vector<u8>, bool>,
        count: u64,
    }
    public fun initialize_registry(ctx: &mut TxContext) {
        let registry = NullifierRegistry {
            id: object::new(ctx),
            spent: table::new(ctx),
            count: 0,
        };
        transfer::share_object(registry);
    }
    public(package) fun record_spend(pool_id: address, registry: &mut NullifierRegistry, nullifier: vector<u8>) {
        assert!(!table::contains(&registry.spent, nullifier), errors::nullifier_spent());
        events::nullifier_spent(pool_id, nullifier);
        table::add(&mut registry.spent, nullifier, true);
        registry.count = registry.count + 1;
    }
    public fun contains(registry: &NullifierRegistry, nullifier: &vector<u8>): bool {
        table::contains(&registry.spent, *nullifier)
    }
    public fun count(registry: &NullifierRegistry): u64 { registry.count }
}
