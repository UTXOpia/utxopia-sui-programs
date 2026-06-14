#[test_only]
module utxopia::ika_policy_tests {
    use sui::test_scenario;
    use utxopia::pool::{Self, Pool, AdminCap};
    use utxopia::redemption::{Self, RedemptionQueue, RedemptionCap};
    use utxopia::ika_policy::{Self, SigningApproval};

    const SENDER: address = @0xA11CE;
    const DWALLET_CAP: address = @0xDCAB;

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    fun init_world(scenario: &mut test_scenario::Scenario) {
        pool::initialize(16, test_scenario::ctx(scenario));
        redemption::initialize_queue(test_scenario::ctx(scenario));
    }

    #[test]
    fun approve_then_consume() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        // request + approve
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);

            redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 50_000, 1_000, test_scenario::ctx(&mut scenario));
            ika_policy::approve_signing(&cap, &pool, &queue, DWALLET_CAP, 0, 800, bytes(32, 0x7a), test_scenario::ctx(&mut scenario));

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(queue);
        };
        test_scenario::next_tx(&mut scenario, SENDER);

        // read + consume the approval
        {
            let pool = test_scenario::take_shared<Pool>(&scenario);
            let queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            let mut approval = test_scenario::take_shared<SigningApproval>(&scenario);

            assert!(ika_policy::approval_redemption_id(&approval) == 0, 0);
            assert!(ika_policy::approval_sighash(&approval) == bytes(32, 0x7a), 1);
            assert!(ika_policy::approval_btc_script(&approval) == bytes(34, 0x51), 2);
            assert!(ika_policy::approval_amount_sats(&approval) == 50_000, 3);
            assert!(ika_policy::approval_dwallet_cap_id(&approval) == DWALLET_CAP, 4);
            assert!(!ika_policy::approval_used(&approval), 5);

            ika_policy::consume_approval(&cap, &pool, &queue, &mut approval, test_scenario::ctx(&mut scenario));
            assert!(ika_policy::approval_used(&approval), 6);

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(queue);
            test_scenario::return_shared(approval);
        };
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 7)]
    fun rejects_amount_over_cap() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);

        // amount > 1 BTC
        redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 200_000_000, 1_000, test_scenario::ctx(&mut scenario));
        ika_policy::approve_signing(&cap, &pool, &queue, DWALLET_CAP, 0, 500, bytes(32, 0x7a), test_scenario::ctx(&mut scenario)); // aborts policy_rejected (7)

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 1)]
    fun rejects_consume_when_paused() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        // request + approve while live
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);

            redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 50_000, 1_000, test_scenario::ctx(&mut scenario));
            ika_policy::approve_signing(&cap, &pool, &queue, DWALLET_CAP, 0, 800, bytes(32, 0x7a), test_scenario::ctx(&mut scenario));

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(queue);
        };
        test_scenario::next_tx(&mut scenario, SENDER);

        // pause, then attempt to consume the pre-pause approval -> aborts pool_paused (1)
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut approval = test_scenario::take_shared<SigningApproval>(&scenario);

            pool::set_paused(&admin, &mut pool, true);
            ika_policy::consume_approval(&cap, &pool, &queue, &mut approval, test_scenario::ctx(&mut scenario));

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_to_sender(&scenario, admin);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(queue);
            test_scenario::return_shared(approval);
        };
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 7)]
    fun rejects_fee_over_cap() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);

        // request allows a high per-request fee, but the policy cap (50k) still rejects 60k
        redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 50_000, 100_000, test_scenario::ctx(&mut scenario));
        ika_policy::approve_signing(&cap, &pool, &queue, DWALLET_CAP, 0, 60_000, bytes(32, 0x7a), test_scenario::ctx(&mut scenario)); // aborts policy_rejected (7)

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 37)]
    fun rejects_double_consume() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            redemption::test_request_redemption(&mut pool, &mut queue, bytes(34, 0x51), 50_000, 1_000, test_scenario::ctx(&mut scenario));
            ika_policy::approve_signing(&cap, &pool, &queue, DWALLET_CAP, 0, 800, bytes(32, 0x7a), test_scenario::ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(queue);
        };
        test_scenario::next_tx(&mut scenario, SENDER);

        let pool = test_scenario::take_shared<Pool>(&scenario);
        let queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
        let mut approval = test_scenario::take_shared<SigningApproval>(&scenario);

        ika_policy::consume_approval(&cap, &pool, &queue, &mut approval, test_scenario::ctx(&mut scenario));
        // second consume -> E_APPROVAL_USED (37)
        ika_policy::consume_approval(&cap, &pool, &queue, &mut approval, test_scenario::ctx(&mut scenario));

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(queue);
        test_scenario::return_shared(approval);
        test_scenario::end(scenario);
    }
}
