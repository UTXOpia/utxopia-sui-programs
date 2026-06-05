#[test_only]
module utxopia::redemption_tests {
    use sui::object;
    use sui::test_scenario;
    use utxopia::btc_deposit::{Self, UtxoSet};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, AdminCap, Pool};
    use utxopia::redemption::{Self, RedemptionQueue};
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    const SENDER: address = @0xA11CE;

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0;
        while (i < n) {
            vector::push_back(&mut out, b);
            i = i + 1;
        };
        out
    }

    fun setup(scenario: &mut test_scenario::Scenario) {
        pool::initialize(16, test_scenario::ctx(scenario));
        commitment_tree::initialize(test_scenario::ctx(scenario));
        btc_deposit::initialize_utxo_set(test_scenario::ctx(scenario));
        nullifier::initialize_registry(test_scenario::ctx(scenario));
        verifier::initialize_registry(test_scenario::ctx(scenario));
        redemption::initialize_queue(test_scenario::ctx(scenario));
    }

    fun bind(
        scenario: &test_scenario::Scenario,
        pool: &mut Pool,
        tree: &CommitmentTree,
        utxo_set: &UtxoSet,
        nullifiers: &NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
    ) {
        let admin = test_scenario::take_from_sender<AdminCap>(scenario);
        pool::set_commitment_tree_id(&admin, pool, object::id(tree));
        pool::set_utxo_set_id(&admin, pool, object::id(utxo_set));
        pool::set_nullifier_registry_id(&admin, pool, object::id(nullifiers));
        pool::set_vk_registry_id(&admin, pool, object::id(vk_registry));
        test_scenario::return_to_sender(scenario, admin);
    }

    fun public_inputs(nullifier_in: vector<u8>, commitment_out: vector<u8>): vector<u8> {
        public_inputs_with_bound(bytes(32, 0), nullifier_in, commitment_out)
    }

    fun public_inputs_with_bound(bound_params_hash: vector<u8>, nullifier_in: vector<u8>, commitment_out: vector<u8>): vector<u8> {
        let mut out = bytes(32, 0);
        vector::append(&mut out, bound_params_hash);
        vector::append(&mut out, nullifier_in);
        vector::append(&mut out, commitment_out);
        out
    }

    #[test, expected_failure(abort_code = 6)]
    fun redeem_requires_public_redemption_output() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &utxo_set, &nullifiers, &vk_registry);

        redemption::redeem(
            &mut pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            &mut queue,
            1,
            1,
            0,
            bytes(32, 0xaa),
            public_inputs(bytes(32, 0x01), bytes(32, 0x02)),
            vector[],
            vector[bytes(32, 0x01)],
            vector[bytes(32, 0x02)],
            vector[],
            vector[],
            vector[],
            vector[],
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 13)]
    fun redeem_binds_public_inputs_to_nullifiers_and_commitments() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &utxo_set, &nullifiers, &vk_registry);

        redemption::redeem(
            &mut pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            &mut queue,
            1,
            1,
            1,
            bytes(32, 0xaa),
            public_inputs(bytes(32, 0x01), bytes(32, 0xff)),
            vector[],
            vector[bytes(32, 0x01)],
            vector[bytes(32, 0x02)],
            vector[bytes(34, 0x51)],
            vector[50_000],
            vector[1_000],
            vector[],
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 13)]
    fun redeem_rejects_mutated_btc_script() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &utxo_set, &nullifiers, &vk_registry);

        let proof_script = bytes(34, 0x51);
        let submitted_script = bytes(34, 0x52);
        let amount = 50_000;
        let commitment = redemption::test_public_redeem_commitment(&pool, amount);
        let commitments_out = vector[redemption::test_public_redeem_commitment(&pool, amount)];
        let bound = redemption::test_redeem_bound_params_hash(vector[proof_script]);

        redemption::redeem(
            &mut pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            &mut queue,
            1,
            1,
            1,
            bytes(32, 0xaa),
            public_inputs_with_bound(bound, bytes(32, 0x01), commitment),
            vector[],
            vector[bytes(32, 0x01)],
            commitments_out,
            vector[submitted_script],
            vector[amount],
            vector[1_000],
            vector[],
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 3)]
    fun redeem_rejects_mutated_public_amount() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &utxo_set, &nullifiers, &vk_registry);

        let script = bytes(34, 0x51);
        let proof_amount = 50_000;
        let submitted_amount = 60_000;
        let commitment = redemption::test_public_redeem_commitment(&pool, proof_amount);
        let commitments_out = vector[redemption::test_public_redeem_commitment(&pool, proof_amount)];
        let bound = redemption::test_redeem_bound_params_hash(vector[script]);

        redemption::redeem(
            &mut pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            &mut queue,
            1,
            1,
            1,
            bytes(32, 0xaa),
            public_inputs_with_bound(bound, bytes(32, 0x01), commitment),
            vector[],
            vector[bytes(32, 0x01)],
            commitments_out,
            vector[bytes(34, 0x51)],
            vector[submitted_amount],
            vector[1_000],
            vector[],
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test]
    fun mark_processing_reserves_selected_utxo() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &utxo_set, &nullifiers, &vk_registry);

        let cap = test_scenario::take_from_sender<utxopia::redemption::RedemptionCap>(&scenario);
        let txid = bytes(32, 0x44);
        btc_deposit::test_add_utxo(
            &mut utxo_set,
            pool::pool_id(&pool),
            txid,
            7,
            60_000,
            test_scenario::ctx(&mut scenario),
        );
        redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 50_000, 1_000, test_scenario::ctx(&mut scenario));
        redemption::mark_processing(&cap, &pool, &mut utxo_set, &mut queue, 0, vector[bytes(32, 0x44)], vector[7], 500);

        assert!(btc_deposit::test_utxo_status(&utxo_set, bytes(32, 0x44), 7) == 1, 0);
        let removed_amount = btc_deposit::test_remove_reserved_utxo(
            &mut utxo_set,
            pool::pool_id(&pool),
            bytes(32, 0x44),
            7,
        );
        assert!(removed_amount == 60_000, 1);
        assert!(!btc_deposit::contains_utxo(&utxo_set, bytes(32, 0x44), 7), 2);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 6)]
    fun mark_processing_rejects_reserved_utxo() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &utxo_set, &nullifiers, &vk_registry);

        let cap = test_scenario::take_from_sender<utxopia::redemption::RedemptionCap>(&scenario);
        let txid = bytes(32, 0x44);
        btc_deposit::test_add_utxo(
            &mut utxo_set,
            pool::pool_id(&pool),
            txid,
            7,
            60_000,
            test_scenario::ctx(&mut scenario),
        );
        redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 50_000, 1_000, test_scenario::ctx(&mut scenario));
        redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x52), 50_000, 1_000, test_scenario::ctx(&mut scenario));
        redemption::mark_processing(&cap, &pool, &mut utxo_set, &mut queue, 0, vector[bytes(32, 0x44)], vector[7], 500);
        redemption::mark_processing(&cap, &pool, &mut utxo_set, &mut queue, 1, vector[bytes(32, 0x44)], vector[7], 500);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }
}
