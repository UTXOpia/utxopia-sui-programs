#[test_only]
module utxopia::pool_admin_tests {
    use sui::clock;
    use sui::object;
    use sui::test_scenario;
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use std::option;
    use utxopia::pool::{Self, AdminCap, AuditorCap, Pool};

    const SENDER: address = @0xA11CE;
    const TIMELOCK_DELAY_MS: u64 = 172_800_000;
    const MAX_LEAVES: u64 = 65_536;

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

    // ---- Finding #8: commitment tree rotation past the 65,536-leaf cap ----

    #[test]
    fun rotate_commitment_tree_rebinds_to_successor() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

        let mut old_tree = commitment_tree::test_new(test_scenario::ctx(&mut scenario)); // number 0
        let new_tree = commitment_tree::test_new_with_number(1, test_scenario::ctx(&mut scenario));
        commitment_tree::test_set_next_index(&mut old_tree, MAX_LEAVES); // fill it

        pool::set_commitment_tree_id(&admin, &mut pool, object::id(&old_tree));
        let old_root = commitment_tree::current_root_bytes(&old_tree);
        pool::rotate_commitment_tree(&admin, &mut pool, &old_tree, &new_tree);

        // Pool is now bound to the successor, not the old full tree.
        pool::assert_commitment_tree(&pool, object::id(&new_tree));
        // Audit CRITICAL #0: the rotated-out tree's final root is preserved so its
        // still-unspent notes remain provable through transact/redeem/unshield.
        assert!(pool::is_historical_root(&pool, &old_root), 100);

        commitment_tree::test_destroy(old_tree);
        commitment_tree::test_destroy(new_tree);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 50)]
    fun rotate_rejects_non_full_tree() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

        let old_tree = commitment_tree::test_new(test_scenario::ctx(&mut scenario)); // not full
        let new_tree = commitment_tree::test_new_with_number(1, test_scenario::ctx(&mut scenario));
        pool::set_commitment_tree_id(&admin, &mut pool, object::id(&old_tree));
        pool::rotate_commitment_tree(&admin, &mut pool, &old_tree, &new_tree);

        commitment_tree::test_destroy(old_tree);
        commitment_tree::test_destroy(new_tree);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 51)]
    fun rotate_rejects_wrong_successor_number() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

        let mut old_tree = commitment_tree::test_new(test_scenario::ctx(&mut scenario)); // number 0
        // number 2 is not the immediate successor of 0.
        let new_tree = commitment_tree::test_new_with_number(2, test_scenario::ctx(&mut scenario));
        commitment_tree::test_set_next_index(&mut old_tree, MAX_LEAVES);
        pool::set_commitment_tree_id(&admin, &mut pool, object::id(&old_tree));
        pool::rotate_commitment_tree(&admin, &mut pool, &old_tree, &new_tree);

        commitment_tree::test_destroy(old_tree);
        commitment_tree::test_destroy(new_tree);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test]
    fun auditor_sets_root_freeze_and_viewing_key() {
        let mut scenario = test_scenario::begin(@0xA11CE);
        pool::initialize_permissioned(16, @0xAD17, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, @0xAD17);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let cap = test_scenario::take_from_sender<AuditorCap>(&scenario);

        assert!(pool::is_permissioned(&pool), 0);
        pool::set_auditor_frozen(&cap, &mut pool, true);
        assert!(pool::auditor_is_frozen(&pool), 1);
        pool::set_auditor_viewing_pubkey(&cap, &mut pool, b"vk-bytes");
        assert!(option::is_some(&pool::auditor_viewing_pubkey(&pool)), 2);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test]
    fun rotate_commitment_tree_permissioned_rebinds() {
        let mut scenario = test_scenario::begin(SENDER);
        pool::initialize_permissioned(16, @0xAD17, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

        let mut old_tree = commitment_tree::test_new(test_scenario::ctx(&mut scenario)); // number 0
        let new_tree = commitment_tree::test_new_with_number(1, test_scenario::ctx(&mut scenario));
        commitment_tree::test_set_next_index(&mut old_tree, MAX_LEAVES); // fill it

        pool::set_commitment_tree_id(&admin, &mut pool, object::id(&old_tree));
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::next_tx(&mut scenario, @0xAD17);

        let auditor_cap = test_scenario::take_from_sender<AuditorCap>(&scenario);
        pool::rotate_commitment_tree_permissioned(&auditor_cap, &mut pool, &old_tree, &new_tree);

        // Pool is now bound to the successor, not the old full tree.
        pool::assert_commitment_tree(&pool, object::id(&new_tree));

        commitment_tree::test_destroy(old_tree);
        commitment_tree::test_destroy(new_tree);
        test_scenario::return_to_sender(&scenario, auditor_cap);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

}
