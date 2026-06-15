module utxopia::transact {
    use sui::object;
    use utxopia::bound_params;
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, Pool};
    use utxopia::public_inputs;
    use utxopia::verifier::{Self, VerifyingKeyRegistry};
    const ANNOUNCEMENT_TYPE_TRANSFER: u8 = 1;
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
        stealth_data: vector<vector<u8>>,
    ) {
        pool::assert_not_paused(pool);
        pool::assert_commitment_tree(pool, object::id(tree));
        pool::assert_nullifier_registry(pool, object::id(nullifiers));
        pool::assert_vk_registry(pool, object::id(vk_registry));
        assert!(nullifiers_in.length() == (n_inputs as u64), errors::invalid_join_split());
        assert!(commitments_out.length() == (n_outputs as u64), errors::invalid_join_split());
        public_inputs::assert_join_split_bindings(&public_inputs, n_inputs, n_outputs, &nullifiers_in, &commitments_out);
        public_inputs::assert_at(&public_inputs, 1, &bound_params::transfer_hash(&stealth_data));
        let proof_root = public_inputs::extract(&public_inputs, 0);
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
        let announce = stealth_data.length() == commitments_out.length();
        let mut j = 0;
        while (j < commitments_out.length()) {
            let leaf_index = commitment_tree::insert_commitment_bytes(tree, pool_id, commitments_out[j]);
            if (announce) {
                events::stealth_announced(
                    pool_id,
                    ANNOUNCEMENT_TYPE_TRANSFER,
                    stealth_data[j],
                    0,
                    commitments_out[j],
                    leaf_index,
                    0u256,
                    vector[],
                );
            };
            j = j + 1;
        };
    }
}
