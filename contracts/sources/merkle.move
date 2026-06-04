module utxopia::merkle {
    use std::hash;
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};

    const FIELD_BYTES_LEN: u64 = 32;

    public(package) fun insert_commitment(pool: &mut Pool, commitment: vector<u8>) {
        pool::assert_not_paused(pool);
        assert!(vector::length(&commitment) == FIELD_BYTES_LEN, errors::invalid_commitment());

        let leaf_index = pool::next_leaf_index(pool);
        events::commitment_inserted(pool::pool_id(pool), leaf_index, commitment);
        pool::increment_leaf_index(pool);
        let current_root = pool::latest_root(pool);
        let new_root = derive_next_root(&current_root, &commitment);
        pool::set_latest_root(pool, new_root);
    }

    public(package) fun derive_next_root(current_root: &vector<u8>, commitment: &vector<u8>): vector<u8> {
        assert!(vector::length(current_root) == FIELD_BYTES_LEN, errors::invalid_commitment());
        assert!(vector::length(commitment) == FIELD_BYTES_LEN, errors::invalid_commitment());

        let mut preimage = *current_root;
        vector::append(&mut preimage, *commitment);
        hash::sha2_256(preimage)
    }
}
