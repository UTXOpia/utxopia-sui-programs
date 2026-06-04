module utxopia::transact {
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, Pool};
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    public fun transact(
        pool: &Pool,
        tree: &mut CommitmentTree,
        nullifiers: &mut NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        vk_hash: vector<u8>,
        public_inputs: vector<u8>,
        proof_points: vector<u8>,
        nullifiers_in: vector<vector<u8>>,
        commitments_out: vector<vector<u8>>,
    ) {
        pool::assert_not_paused(pool);
        assert!(nullifiers_in.length() == (n_inputs as u64), errors::invalid_join_split());
        assert!(commitments_out.length() == (n_outputs as u64), errors::invalid_join_split());
        // Validates total length (and thus that index 0/1 are present) before slicing.
        assert_bound_public_inputs(&public_inputs, n_inputs, n_outputs, &nullifiers_in, &commitments_out);

        // History-aware Merkle root check: the proof's root (public input 0) must be the
        // current root OR any recent root, so a deposit landing between proof-gen and
        // submission does not invalidate an otherwise-valid proof.
        let proof_root = extract_public_input(&public_inputs, 0);
        assert!(commitment_tree::is_valid_root_bytes(tree, &proof_root), errors::stale_merkle_root());

        let verified = verifier::verify_join_split(
            vk_registry,
            n_inputs,
            n_outputs,
            vk_hash,
            public_inputs,
            proof_points,
        );
        assert!(verified, errors::verification_failed());

        let pool_id = pool::pool_id(pool);
        events::join_split_verified(pool_id, n_inputs, n_outputs, vk_hash);

        let mut i = 0;
        while (i < nullifiers_in.length()) {
            nullifier::record_spend(pool_id, nullifiers, nullifiers_in[i]);
            i = i + 1;
        };

        let mut j = 0;
        while (j < commitments_out.length()) {
            commitment_tree::insert_commitment_bytes(tree, pool_id, commitments_out[j]);
            j = j + 1;
        };
    }

    fun assert_bound_public_inputs(
        public_inputs: &vector<u8>,
        n_inputs: u8,
        n_outputs: u8,
        nullifiers_in: &vector<vector<u8>>,
        commitments_out: &vector<vector<u8>>,
    ) {
        let expected_len = ((2 + (n_inputs as u64) + (n_outputs as u64)) * 32);
        assert!(public_inputs.length() == expected_len, errors::invalid_join_split());

        let mut i = 0;
        while (i < (n_inputs as u64)) {
            assert_public_input_at(public_inputs, 2 + i, &nullifiers_in[i]);
            i = i + 1;
        };

        let mut j = 0;
        while (j < (n_outputs as u64)) {
            assert_public_input_at(public_inputs, 2 + (n_inputs as u64) + j, &commitments_out[j]);
            j = j + 1;
        };
    }

    fun assert_public_input_at(public_inputs: &vector<u8>, index: u64, expected: &vector<u8>) {
        assert!(expected.length() == 32, errors::invalid_join_split());
        let start = index * 32;
        let mut i = 0;
        while (i < 32) {
            assert!(*public_inputs.borrow(start + i) == *expected.borrow(i), errors::invalid_join_split());
            i = i + 1;
        };
    }

    fun extract_public_input(public_inputs: &vector<u8>, index: u64): vector<u8> {
        let start = index * 32;
        let mut out = vector[];
        let mut i = 0;
        while (i < 32) {
            vector::push_back(&mut out, *public_inputs.borrow(start + i));
            i = i + 1;
        };
        out
    }
}
