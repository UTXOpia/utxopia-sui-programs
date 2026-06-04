#[test_only]
module utxopia::commitment_tree_tests {
    use sui::test_scenario;
    use utxopia::commitment_tree::{Self as ct, CommitmentTree};

    const SENDER: address = @0xA11CE;
    const POSEIDON_1_2: u256 =
        0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a;

    // --- helpers: independently fold a leaf set using the native primitives ---

    fun single_leaf_root(leaf: u256): u256 {
        let mut r = leaf;
        let mut level = 0;
        while (level < 16) {
            r = ct::test_hash_node(r, ct::test_zero_hash(level));
            level = level + 1;
        };
        r
    }

    fun two_leaf_root(l0: u256, l1: u256): u256 {
        let mut r = ct::test_hash_node(l0, l1); // level-0 parent
        let mut level = 1;
        while (level < 16) {
            r = ct::test_hash_node(r, ct::test_zero_hash(level));
            level = level + 1;
        };
        r
    }

    // r (the BN254 scalar modulus) as 32 big-endian bytes — a non-canonical field input.
    fun modulus_be(): vector<u8> {
        vector[
            0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
            0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
            0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
            0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
        ]
    }

    #[test] // U1: node hash order + parameterization
    fun u1_hash_node_matches_circomlib() {
        assert!(ct::test_hash_node(1, 2) == POSEIDON_1_2, 0);
    }

    #[test] // U2: recompute the zero ladder from ZERO[0]=0 and match the literals
    fun u2_zero_ladder_recompute() {
        assert!(ct::test_zero_hash(0) == 0, 0);
        let mut z: u256 = 0;
        let mut level = 0;
        while (level < 16) {
            z = ct::test_hash_node(z, z);
            assert!(z == ct::test_zero_hash(level + 1), level);
            level = level + 1;
        };
        assert!(z == ct::empty_root(), 100);
    }

    #[test] // U3: empty tree invariants
    fun u3_empty_tree() {
        let mut scenario = test_scenario::begin(SENDER);
        let tree = ct::test_new(test_scenario::ctx(&mut scenario));
        assert!(ct::current_root(&tree) == ct::empty_root(), 0);
        assert!(ct::next_index(&tree) == 0, 1);
        assert!(!ct::is_full(&tree), 2);
        ct::test_destroy(tree);
        test_scenario::end(scenario);
    }

    #[test] // U4: single insert — exact root, history retains empty root
    fun u4_single_insert() {
        let mut scenario = test_scenario::begin(SENDER);
        let mut tree = ct::test_new(test_scenario::ctx(&mut scenario));
        let empty = ct::current_root(&tree);

        let idx = ct::insert_leaf(&mut tree, 111);
        assert!(idx == 0, 0);
        assert!(ct::next_index(&tree) == 1, 1);
        assert!(ct::current_root(&tree) == single_leaf_root(111), 2);
        assert!(ct::current_root(&tree) != empty, 3);
        // the prior (empty) root must still validate via history
        assert!(ct::is_valid_root(&tree, empty), 4);
        assert!(ct::is_valid_root(&tree, ct::current_root(&tree)), 5);

        ct::test_destroy(tree);
        test_scenario::end(scenario);
    }

    #[test] // U5: two inserts — exact level-0 combine + zero fold
    fun u5_two_inserts() {
        let mut scenario = test_scenario::begin(SENDER);
        let mut tree = ct::test_new(test_scenario::ctx(&mut scenario));
        ct::insert_leaf(&mut tree, 111);
        ct::insert_leaf(&mut tree, 222);
        assert!(ct::next_index(&tree) == 2, 0);
        assert!(ct::current_root(&tree) == two_leaf_root(111, 222), 1);
        ct::test_destroy(tree);
        test_scenario::end(scenario);
    }

    #[test] // U6: is_valid_root over history; 0 and unknown roots rejected
    fun u6_root_history() {
        let mut scenario = test_scenario::begin(SENDER);
        let mut tree = ct::test_new(test_scenario::ctx(&mut scenario));

        let r0 = ct::current_root(&tree);
        ct::insert_leaf(&mut tree, 1);
        let r1 = ct::current_root(&tree);
        ct::insert_leaf(&mut tree, 2);
        let r2 = ct::current_root(&tree);
        ct::insert_leaf(&mut tree, 3);

        assert!(ct::is_valid_root(&tree, r0), 0);
        assert!(ct::is_valid_root(&tree, r1), 1);
        assert!(ct::is_valid_root(&tree, r2), 2);
        assert!(ct::is_valid_root(&tree, ct::current_root(&tree)), 3);
        assert!(!ct::is_valid_root(&tree, 0), 4);          // R11: sentinel rejected
        assert!(!ct::is_valid_root(&tree, 0xdeadbeef), 5); // unknown rejected

        ct::test_destroy(tree);
        test_scenario::end(scenario);
    }

    #[test] // U11: determinism — two fresh trees, same sequence, same root
    fun u11_determinism() {
        let mut scenario = test_scenario::begin(SENDER);
        let mut a = ct::test_new(test_scenario::ctx(&mut scenario));
        let mut b = ct::test_new(test_scenario::ctx(&mut scenario));
        let mut k: u256 = 1;
        while (k <= 5) {
            ct::insert_leaf(&mut a, k);
            ct::insert_leaf(&mut b, k);
            k = k + 1;
        };
        assert!(ct::current_root(&a) == ct::current_root(&b), 0);
        ct::test_destroy(a);
        ct::test_destroy(b);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 18)] // U8: reject non-canonical field element
    fun u8_rejects_out_of_field() {
        ct::field_from_be_bytes(&modulus_be());
    }

    #[test, expected_failure(abort_code = 17)] // U10: tree-full aborts
    fun u10_tree_full() {
        let mut scenario = test_scenario::begin(SENDER);
        let mut tree = ct::test_new(test_scenario::ctx(&mut scenario));
        ct::test_set_next_index(&mut tree, 65_536);
        ct::insert_leaf(&mut tree, 7); // should abort tree_full before consuming
        ct::test_destroy(tree);
        test_scenario::end(scenario);
    }
}
