#[test_only]
module utxopia::btc_deposit_tests {
    use sui::test_scenario;
    use utxopia::btc_light_client;
    use utxopia::btc_deposit::{Self, BtcDepositRegistry};
    use utxopia::pool::{Self, Pool};

    const SENDER: address = @0xA11CE;

    #[test]
    fun completes_verified_deposit_once() {
        let mut scenario = test_scenario::begin(SENDER);

        pool::initialize(16, bytes32(0), test_scenario::ctx(&mut scenario));
        btc_deposit::initialize_registry(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);

        let verified_deposit = btc_light_client::new_verified_deposit(
            bytes32(1),
            0,
            25_000,
            bytes64(3),
            bytes32(4),
            bytes32(5),
            test_scenario::ctx(&mut scenario),
        );

        btc_deposit::complete_verified_deposit(
            &mut pool,
            &mut registry,
            verified_deposit,
        );

        assert!(btc_deposit::claimed_count(&registry) == 1, 0);
        assert!(pool::latest_root(&pool) == bytes32(5), 1);
        assert!(pool::latest_root_index(&pool) == 1, 2);

        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 15)]
    fun rejects_duplicate_deposit_outpoint() {
        let mut scenario = test_scenario::begin(SENDER);

        pool::initialize(16, bytes32(0), test_scenario::ctx(&mut scenario));
        btc_deposit::initialize_registry(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);

        let verified_deposit = btc_light_client::new_verified_deposit(
            bytes32(1),
            0,
            25_000,
            bytes64(3),
            bytes32(4),
            bytes32(5),
            test_scenario::ctx(&mut scenario),
        );
        btc_deposit::complete_verified_deposit(&mut pool, &mut registry, verified_deposit);

        let duplicate_verified_deposit = btc_light_client::new_verified_deposit(
            bytes32(1),
            0,
            25_000,
            bytes64(3),
            bytes32(8),
            bytes32(7),
            test_scenario::ctx(&mut scenario),
        );
        btc_deposit::complete_verified_deposit(&mut pool, &mut registry, duplicate_verified_deposit);

        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    fun bytes32(byte: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 32) {
            vector::push_back(&mut out, byte);
            i = i + 1;
        };
        out
    }

    fun bytes64(byte: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 64) {
            vector::push_back(&mut out, byte);
            i = i + 1;
        };
        out
    }
}
