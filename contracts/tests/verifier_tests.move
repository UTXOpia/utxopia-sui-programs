#[test_only]
module utxopia::verifier_tests {
    use sui::object;
    use sui::test_scenario;
    use utxopia::pool::{Self, AdminCap, Pool};
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    const SENDER: address = @0xA11CE;

    #[test]
    fun registers_prepared_key_metadata() {
        let mut scenario = test_scenario::begin(SENDER);

        pool::initialize(16, test_scenario::ctx(&mut scenario));
        verifier::initialize_registry(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        pool::set_vk_registry_id(&admin_cap, &mut pool, object::id(&registry));

        verifier::register_prepared_key(
            &admin_cap,
            &pool,
            &mut registry,
            2,
            2,
            6,
            vector[
                1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            ],
            vector[1],
            vector[2],
            vector[3],
            vector[4],
        );

        assert!(
            verifier::contains_key(
                &registry,
                2,
                2,
                &vector[
                    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                ],
            ),
            0,
        );

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 40)]
    fun rejects_unbound_vk_registry() {
        let mut scenario = test_scenario::begin(SENDER);

        pool::initialize(16, test_scenario::ctx(&mut scenario));
        verifier::initialize_registry(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
        let pool = test_scenario::take_shared<Pool>(&scenario);
        let mut registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);

        verifier::register_prepared_key(
            &admin_cap,
            &pool,
            &mut registry,
            2,
            2,
            6,
            vector[
                1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            ],
            vector[1],
            vector[2],
            vector[3],
            vector[4],
        );

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }
}
