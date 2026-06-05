#[test_only]
module utxopia::redemption_tests {
    use sui::object;
    use sui::test_scenario;
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
        nullifier::initialize_registry(test_scenario::ctx(scenario));
        verifier::initialize_registry(test_scenario::ctx(scenario));
        redemption::initialize_queue(test_scenario::ctx(scenario));
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

    fun public_inputs(nullifier_in: vector<u8>, commitment_out: vector<u8>): vector<u8> {
        let mut out = bytes(64, 0);
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
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry);

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
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
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
        let mut nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry);

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
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }
}
