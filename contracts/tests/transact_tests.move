#[test_only]
module utxopia::transact_tests {
    use sui::object;
    use sui::test_scenario;
    use utxopia::bound_params;
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, AdminCap, Pool};
    use utxopia::transact;
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    const SENDER: address = @0xA11CE;

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    fun setup(scenario: &mut test_scenario::Scenario) {
        pool::initialize(16, test_scenario::ctx(scenario));
        commitment_tree::initialize(test_scenario::ctx(scenario));
        nullifier::initialize_registry(test_scenario::ctx(scenario));
        verifier::initialize_registry(test_scenario::ctx(scenario));
    }

    fun bind(
        scenario: &test_scenario::Scenario,
        pool: &mut Pool,
        tree: &CommitmentTree,
        nullifiers: &NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
    ) {
        let admin = test_scenario::take_from_sender<AdminCap>(scenario);
        pool::set_commitment_tree_id(&admin, pool, object::id(tree));
        pool::set_nullifier_registry_id(&admin, pool, object::id(nullifiers));
        pool::set_vk_registry_id(&admin, pool, object::id(vk_registry));
        test_scenario::return_to_sender(scenario, admin);
    }

    // Cross-language vector: must equal the SDK's computeBoundParamsHash for the
    // same stealth_data + Sui chain id (bound-params.test.ts pins the same value).
    #[test]
    fun transfer_hash_matches_sdk_vector() {
        let got = bound_params::test_transfer_hash(vector[bytes(72, 0x11)]);
        // Length-prefixed stealth-data encoding (audit #51/#52/#54). Locked to the SDK.
        let expected = x"089f78cb332df8a2af8c34e4bf4c8477daf60a38dd6eddd43b6161c4ff8ad9da";
        assert!(got == expected, 0);
    }

    // A bound_params_hash that doesn't match the supplied stealth_data is rejected.
    #[test, expected_failure(abort_code = 13)]
    fun transact_rejects_unbound_bound_params_hash() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry);

        // bound hash committed for stealth_data A, but B is submitted → mismatch
        // (aborts at the index-1 binding, before the root check).
        let bound = bound_params::test_transfer_hash(vector[bytes(72, 0x11)]);
        let mut public_inputs = bytes(32, 0);
        vector::append(&mut public_inputs, bound);
        vector::append(&mut public_inputs, bytes(32, 0x01));
        vector::append(&mut public_inputs, bytes(32, 0x02));

        transact::transact(
            &pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            1,
            1,
            bytes(32, 0xaa),
            public_inputs,
            vector[],
            vector[bytes(32, 0x01)],
            vector[bytes(32, 0x02)],
            vector[bytes(72, 0x12)],
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::end(scenario);
    }

    // Finding #9: a non-canonical nullifier (>= BN254_FR) must be rejected so it can't be
    // replayed as `N + BN254_FR` to dodge the byte-equality dedup in NullifierRegistry.
    #[test, expected_failure(abort_code = 18)]
    fun transact_rejects_non_canonical_nullifier() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry);

        // 0xff..ff > BN254_FR. Aborts (commitment_out_of_field) at the nullifier range check.
        let non_canonical = bytes(32, 0xff);
        let bound = bound_params::test_transfer_hash(vector[bytes(72, 0x11)]);
        let mut public_inputs = bytes(32, 0);
        vector::append(&mut public_inputs, bound);
        vector::append(&mut public_inputs, non_canonical);
        vector::append(&mut public_inputs, bytes(32, 0x02));

        transact::transact(
            &pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            1,
            1,
            bytes(32, 0xaa),
            public_inputs,
            vector[],
            vector[non_canonical],
            vector[bytes(32, 0x02)],
            vector[bytes(72, 0x11)],
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::end(scenario);
    }
}
