module utxopia::public_inputs {
    use utxopia::commitment_tree;
    use utxopia::errors;
    public(package) fun assert_join_split_bindings(
        public_inputs: &vector<u8>,
        n_inputs: u8,
        n_outputs: u8,
        nullifiers_in: &vector<vector<u8>>,
        commitments_out: &vector<vector<u8>>,
    ) {
        assert!(public_inputs.length() == ((2 + (n_inputs as u64) + (n_outputs as u64)) * 32), errors::invalid_join_split());
        let mut i = 0u64;
        while (i < (n_inputs as u64)) {
            // Reject non-canonical nullifier encodings (>= BN254_FR). Nullifiers are
            // deduped by raw byte equality in NullifierRegistry, so without this an
            // attacker could replay a spend as `N + BN254_FR` (congruent in-field, so
            // the proof still verifies) but a different 32-byte dedup key -> double spend.
            commitment_tree::field_from_be_bytes(&nullifiers_in[i]);
            assert_at(public_inputs, 2 + i, &nullifiers_in[i]);
            i = i + 1;
        };
        let mut j = 0u64;
        while (j < (n_outputs as u64)) {
            assert_at(public_inputs, 2 + (n_inputs as u64) + j, &commitments_out[j]);
            j = j + 1;
        };
    }
    public(package) fun assert_at(public_inputs: &vector<u8>, index: u64, expected: &vector<u8>) {
        assert!(expected.length() == 32, errors::invalid_join_split());
        let start = index * 32;
        let mut i = 0u64;
        while (i < 32) {
            assert!(*public_inputs.borrow(start + 31 - i) == *expected.borrow(i), errors::invalid_join_split());
            i = i + 1;
        };
    }
    public(package) fun extract(public_inputs: &vector<u8>, index: u64): vector<u8> {
        let start = index * 32;
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 32) {
            vector::push_back(&mut out, *public_inputs.borrow(start + 31 - i));
            i = i + 1;
        };
        out
    }
}
