module utxopia::commitment_tree {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::poseidon;
    use utxopia::errors;
    use utxopia::events;
    const TREE_DEPTH: u64 = 16;
    const MAX_LEAVES: u64 = 65_536;
    const ROOT_HISTORY_SIZE: u64 = 100;
    const BN254_FR: u256 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    public struct CommitmentTree has key {
        id: UID,
        tree_number: u32,
        next_index: u64,
        current_root: u256,
        filled_subtrees: vector<u256>,
        root_history: vector<u256>,
        root_history_index: u64,
    }
    public fun initialize(ctx: &mut TxContext) {
        create(0, ctx)
    }
    public(package) fun create(tree_number: u32, ctx: &mut TxContext) {
        transfer::share_object(new_tree(tree_number, ctx))
    }
    fun new_tree(tree_number: u32, ctx: &mut TxContext): CommitmentTree {
        let mut filled_subtrees = vector[];
        let mut level = 0;
        while (level < TREE_DEPTH) {
            vector::push_back(&mut filled_subtrees, zero_hash(level));
            level = level + 1;
        };
        let mut root_history = vector[];
        let mut i = 0;
        while (i < ROOT_HISTORY_SIZE) {
            vector::push_back(&mut root_history, 0u256);
            i = i + 1;
        };
        CommitmentTree {
            id: object::new(ctx),
            tree_number,
            next_index: 0,
            current_root: zero_hash(TREE_DEPTH),
            filled_subtrees,
            root_history,
            root_history_index: 0,
        }
    }
    public(package) fun insert_leaf(t: &mut CommitmentTree, leaf: u256): u64 {
        assert!(leaf < BN254_FR, errors::commitment_out_of_field());
        let leaf_index = t.next_index;
        assert!(leaf_index < MAX_LEAVES, errors::tree_full());
        let mut current = leaf;
        let mut index = leaf_index;
        let mut level = 0;
        while (level < TREE_DEPTH) {
            if (index % 2 == 0) {
                *vector::borrow_mut(&mut t.filled_subtrees, level) = current;
                current = hash_node(current, zero_hash(level));
            } else {
                let left = *vector::borrow(&t.filled_subtrees, level);
                current = hash_node(left, current);
            };
            index = index / 2;
            level = level + 1;
        };
        update_root(t, current);
        t.next_index = leaf_index + 1;
        leaf_index
    }
    public(package) fun insert_commitment_bytes(
        t: &mut CommitmentTree,
        pool_id: address,
        commitment_be: vector<u8>,
    ): u64 {
        let leaf = field_from_be_bytes(&commitment_be);
        let leaf_index = insert_leaf(t, leaf);
        events::commitment_inserted(pool_id, leaf_index, commitment_be);
        events::merkle_root_updated(pool_id, t.next_index, field_to_be_bytes(t.current_root));
        leaf_index
    }
    fun hash_node(left: u256, right: u256): u256 {
        poseidon::poseidon_bn254(&vector[left, right])
    }
    fun update_root(t: &mut CommitmentTree, new_root: u256) {
        let pos = t.root_history_index % ROOT_HISTORY_SIZE;
        *vector::borrow_mut(&mut t.root_history, pos) = t.current_root;
        t.root_history_index = t.root_history_index + 1;
        t.current_root = new_root;
    }
    public fun is_valid_root(t: &CommitmentTree, root: u256): bool {
        if (root == 0) return false;
        if (root == t.current_root) return true;
        let mut i = 0;
        let len = vector::length(&t.root_history);
        while (i < len) {
            if (*vector::borrow(&t.root_history, i) == root) return true;
            i = i + 1;
        };
        false
    }
    public fun is_valid_root_bytes(t: &CommitmentTree, root_be: &vector<u8>): bool {
        let v = be_bytes_to_u256(root_be);
        if (v >= BN254_FR) return false;
        is_valid_root(t, v)
    }
    public fun current_root(t: &CommitmentTree): u256 { t.current_root }
    public fun current_root_bytes(t: &CommitmentTree): vector<u8> {
        field_to_be_bytes(t.current_root)
    }
    public fun next_index(t: &CommitmentTree): u64 { t.next_index }
    public fun is_full(t: &CommitmentTree): bool { t.next_index >= MAX_LEAVES }
    public fun tree_number(t: &CommitmentTree): u32 { t.tree_number }
    public fun id(t: &CommitmentTree): address { object::uid_to_address(&t.id) }
    /// Mint and share a fresh successor tree (tree_number + 1). Only permitted once the
    /// current tree is full, so this cannot be used to spam trees while one has capacity.
    /// Rebinding the pool to the new tree is a separate AdminCap-gated step
    /// (`pool::rotate_commitment_tree`).
    public fun create_successor(prev: &CommitmentTree, ctx: &mut TxContext) {
        assert!(is_full(prev), errors::tree_not_full());
        create(prev.tree_number + 1, ctx)
    }
    public fun empty_root(): u256 { zero_hash(TREE_DEPTH) }
    public(package) fun field_from_be_bytes(b: &vector<u8>): u256 {
        let v = be_bytes_to_u256(b);
        assert!(v < BN254_FR, errors::commitment_out_of_field());
        v
    }
    public fun field_to_be_bytes(x: u256): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 32) {
            let shift = (8 * (31 - i)) as u8;
            let byte = ((x >> shift) & 0xff) as u8;
            vector::push_back(&mut out, byte);
            i = i + 1;
        };
        out
    }
    fun be_bytes_to_u256(b: &vector<u8>): u256 {
        assert!(vector::length(b) == 32, errors::invalid_commitment());
        let mut acc: u256 = 0;
        let mut i = 0;
        while (i < 32) {
            acc = (acc << 8) | (*vector::borrow(b, i) as u256);
            i = i + 1;
        };
        acc
    }
    fun zero_hash(level: u64): u256 {
        if (level == 0) { 0x0000000000000000000000000000000000000000000000000000000000000000 }
        else if (level == 1) { 0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864 }
        else if (level == 2) { 0x1069673dcdb12263df301a6ff584a7ec261a44cb9dc68df067a4774460b1f1e1 }
        else if (level == 3) { 0x18f43331537ee2af2e3d758d50f72106467c6eea50371dd528d57eb2b856d238 }
        else if (level == 4) { 0x07f9d837cb17b0d36320ffe93ba52345f1b728571a568265caac97559dbc952a }
        else if (level == 5) { 0x2b94cf5e8746b3f5c9631f4c5df32907a699c58c94b2ad4d7b5cec1639183f55 }
        else if (level == 6) { 0x2dee93c5a666459646ea7d22cca9e1bcfed71e6951b953611d11dda32ea09d78 }
        else if (level == 7) { 0x078295e5a22b84e982cf601eb639597b8b0515a88cb5ac7fa8a4aabe3c87349d }
        else if (level == 8) { 0x2fa5e5f18f6027a6501bec864564472a616b2e274a41211a444cbe3a99f3cc61 }
        else if (level == 9) { 0x0e884376d0d8fd21ecb780389e941f66e45e7acce3e228ab3e2156a614fcd747 }
        else if (level == 10) { 0x1b7201da72494f1e28717ad1a52eb469f95892f957713533de6175e5da190af2 }
        else if (level == 11) { 0x1f8d8822725e36385200c0b201249819a6e6e1e4650808b5bebc6bface7d7636 }
        else if (level == 12) { 0x2c5d82f66c914bafb9701589ba8cfcfb6162b0a12acf88a8d0879a0471b5f85a }
        else if (level == 13) { 0x14c54148a0940bb820957f5adf3fa1134ef5c4aaa113f4646458f270e0bfbfd0 }
        else if (level == 14) { 0x190d33b12f986f961e10c0ee44d8b9af11be25588cad89d416118e4bf4ebe80c }
        else if (level == 15) { 0x22f98aa9ce704152ac17354914ad73ed1167ae6596af510aa5b3649325e06c92 }
        else if (level == 16) { 0x2a7c7c9b6ce5880b9f6f228d72bf6a575a526f29c66ecceef8b753d38bba7323 }
        else { abort errors::invalid_commitment() }
    }
    #[test_only]
    public fun test_hash_node(left: u256, right: u256): u256 { hash_node(left, right) }
    #[test_only]
    public fun test_zero_hash(level: u64): u256 { zero_hash(level) }
    #[test_only]
    public fun test_field_modulus(): u256 { BN254_FR }
    #[test_only]
    public fun test_new(ctx: &mut TxContext): CommitmentTree { new_tree(0, ctx) }
    #[test_only]
    public fun test_new_with_number(tree_number: u32, ctx: &mut TxContext): CommitmentTree {
        new_tree(tree_number, ctx)
    }
    #[test_only]
    public fun test_set_next_index(t: &mut CommitmentTree, n: u64) { t.next_index = n; }
    #[test_only]
    public fun test_destroy(t: CommitmentTree) {
        let CommitmentTree {
            id,
            tree_number: _,
            next_index: _,
            current_root: _,
            filled_subtrees: _,
            root_history: _,
            root_history_index: _,
        } = t;
        object::delete(id);
    }
}
