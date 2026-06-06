#[test_only]
module utxopia::pool_admin_tests {
    use sui::clock;
    use sui::test_scenario;
    use utxopia::pool::{Self, AdminCap, Pool};

    const SENDER: address = @0xA11CE;
    const TIMELOCK_DELAY_MS: u64 = 172_800_000;

    fun setup(scenario: &mut test_scenario::Scenario) {
        pool::initialize(16, test_scenario::ctx(scenario));
    }

    #[test, expected_failure(abort_code = 43)]
    fun rejects_deposit_config_execution_before_timelock() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        pool::propose_deposit_config_update(&admin, &mut pool, 1_000, 100_000, 25, 500, &clk);
        pool::execute_deposit_config_update(&mut pool, &clk);

        clock::destroy_for_testing(clk);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test]
    fun executes_deposit_config_after_timelock() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        let mut clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        pool::propose_deposit_config_update(&admin, &mut pool, 1_000, 100_000, 25, 500, &clk);
        assert!(pool::min_deposit_sats(&pool) == 0, 0);
        clock::increment_for_testing(&mut clk, TIMELOCK_DELAY_MS);
        pool::execute_deposit_config_update(&mut pool, &clk);

        assert!(pool::min_deposit_sats(&pool) == 1_000, 1);
        assert!(pool::max_deposit_sats(&pool) == 100_000, 2);
        assert!(pool::deposit_fee_bps(&pool) == 25, 3);
        assert!(pool::service_fee_sats(&pool) == 500, 4);
        assert!(std::option::is_none(&pool::pending_execute_after_ms(&pool)), 5);

        clock::destroy_for_testing(clk);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 42)]
    fun cancel_clears_pending_deposit_config() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        let mut clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        pool::propose_deposit_config_update(&admin, &mut pool, 1_000, 100_000, 25, 500, &clk);
        pool::cancel_deposit_config_update(&admin, &mut pool);
        clock::increment_for_testing(&mut clk, TIMELOCK_DELAY_MS);
        pool::execute_deposit_config_update(&mut pool, &clk);

        clock::destroy_for_testing(clk);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }
}
