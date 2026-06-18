#[test_only]
module utxopia::ika_policy_tests {
    use sui::object;
    use sui::test_scenario;
    use utxopia::pool::{Self, Pool, AdminCap};
    use utxopia::redemption::{Self, RedemptionQueue, RedemptionCap};
    use utxopia::btc_deposit::{Self, UtxoSet};
    use utxopia::ika_policy::{Self, SigningApproval};
    use utxopia::sighash;

    const SENDER: address = @0xA11CE;
    const DWALLET_CAP: address = @0xDCAB;

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    // 34-byte taproot scriptPubKey 0x5120 || 32-byte x-only key.
    fun spk(fill: u8): vector<u8> {
        let mut v = vector[0x51u8, 0x20u8];
        vector::append(&mut v, bytes(32, fill));
        v
    }

    fun init_world(scenario: &mut test_scenario::Scenario) {
        pool::initialize(16, test_scenario::ctx(scenario));
        btc_deposit::initialize_utxo_set(test_scenario::ctx(scenario));
        redemption::initialize_queue(test_scenario::ctx(scenario));
    }

    // Enqueue a redemption, reserve one pool UTXO, and mark it processing — the
    // state `approve_signing` now requires. Binds the utxo_set + pool script first.
    fun prepare_processed(
        admin: &AdminCap,
        pool: &mut Pool,
        utxo_set: &mut UtxoSet,
        queue: &mut RedemptionQueue,
        cap: &RedemptionCap,
        btc_script: vector<u8>,
        amount: u64,
        max_fee: u64,
        utxo_txid: vector<u8>,
        utxo_vout: u32,
        utxo_amount: u64,
        est_fee: u64,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        pool::set_utxo_set_id(admin, pool, object::id(utxo_set));
        pool::set_btc_pool_script(admin, pool, spk(0xAA));
        pool::set_redemption_queue_id(admin, pool, object::id(queue));
        redemption::test_request_redemption(pool, queue, btc_script, amount, max_fee, ctx);
        btc_deposit::test_add_utxo(utxo_set, pool::pool_id(pool), utxo_txid, utxo_vout, utxo_amount, ctx);
        redemption::mark_processing(cap, pool, utxo_set, queue, 0, vector[utxo_txid], vector[utxo_vout], est_fee);
    }

    // Reconstruct the single-input redemption sighash the policy expects.
    fun expected_sighash(
        dest: vector<u8>, amount: u64, utxo_txid: vector<u8>, utxo_vout: u32,
        utxo_amount: u64, est_fee: u64,
    ): vector<u8> {
        let pool_script = spk(0xAA);
        let change = utxo_amount - amount - est_fee;
        let mut out_amounts = vector[amount];
        let mut out_spks = vector[dest];
        if (change > 330) {
            vector::push_back(&mut out_amounts, change);
            vector::push_back(&mut out_spks, pool_script);
        };
        sighash::taproot_keyspend_sighash(
            2, 0,
            &vector[utxo_txid], &vector[utxo_vout], &vector[utxo_amount],
            &vector[0xFFFF_FFFDu32], &vector[pool_script],
            &out_amounts, &out_spks, 0,
        )
    }

    #[test]
    fun approve_then_consume() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let dest = spk(0xBB);
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
            let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

            prepare_processed(
                &admin, &mut pool, &mut utxo_set, &mut queue, &cap,
                dest, 50_000, 12_500, bytes(32, 0x44), 7, 100_000, 1_000,
                test_scenario::ctx(&mut scenario),
            );
            let sh = expected_sighash(dest, 50_000, bytes(32, 0x44), 7, 100_000, 1_000);
            ika_policy::approve_signing(
                &cap, &pool, &queue, &utxo_set, DWALLET_CAP, 0, 0, 1_000, sh,
                test_scenario::ctx(&mut scenario),
            );

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_to_sender(&scenario, admin);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(utxo_set);
            test_scenario::return_shared(queue);
        };
        test_scenario::next_tx(&mut scenario, SENDER);

        {
            let pool = test_scenario::take_shared<Pool>(&scenario);
            let queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            let mut approval = test_scenario::take_shared<SigningApproval>(&scenario);

            assert!(ika_policy::approval_redemption_id(&approval) == 0, 0);
            assert!(ika_policy::approval_input_index(&approval) == 0, 1);
            assert!(ika_policy::approval_btc_script(&approval) == dest, 2);
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

    // The core fix: a sighash that does NOT match the reconstructed redemption tx
    // (i.e. a relayer trying to get the dWallet to sign an arbitrary BTC tx) is
    // rejected. abort_code 7 == errors::policy_rejected().
    #[test, expected_failure(abort_code = 7)]
    fun rejects_tampered_sighash() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

        prepare_processed(
            &admin, &mut pool, &mut utxo_set, &mut queue, &cap,
            spk(0xBB), 50_000, 12_500, bytes(32, 0x44), 7, 100_000, 1_000,
            test_scenario::ctx(&mut scenario),
        );
        // Attacker-chosen sighash (e.g. of a custody-draining tx) — not the bound one.
        ika_policy::approve_signing(
            &cap, &pool, &queue, &utxo_set, DWALLET_CAP, 0, 0, 1_000, bytes(32, 0x7a),
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    // Approving a request that never went through mark_processing is rejected.
    #[test, expected_failure(abort_code = 7)]
    fun rejects_unprocessed_request() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        pool::set_utxo_set_id(&admin, &mut pool, object::id(&utxo_set));
        pool::set_btc_pool_script(&admin, &mut pool, spk(0xAA));
        pool::set_redemption_queue_id(&admin, &mut pool, object::id(&queue));
        test_scenario::return_to_sender(&scenario, admin);

        redemption::test_request_redemption(&mut pool, &mut queue, spk(0xBB), 50_000, 12_500, test_scenario::ctx(&mut scenario));
        // No mark_processing -> request_is_processing == false -> policy_rejected (7)
        ika_policy::approve_signing(
            &cap, &pool, &queue, &utxo_set, DWALLET_CAP, 0, 0, 1_000, bytes(32, 0x7a),
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(queue);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 1)]
    fun rejects_consume_when_paused() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let dest = spk(0xBB);
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
            let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

            prepare_processed(
                &admin, &mut pool, &mut utxo_set, &mut queue, &cap,
                dest, 50_000, 12_500, bytes(32, 0x44), 7, 100_000, 1_000,
                test_scenario::ctx(&mut scenario),
            );
            let sh = expected_sighash(dest, 50_000, bytes(32, 0x44), 7, 100_000, 1_000);
            ika_policy::approve_signing(
                &cap, &pool, &queue, &utxo_set, DWALLET_CAP, 0, 0, 1_000, sh,
                test_scenario::ctx(&mut scenario),
            );

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_to_sender(&scenario, admin);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(utxo_set);
            test_scenario::return_shared(queue);
        };
        test_scenario::next_tx(&mut scenario, SENDER);

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

    #[test, expected_failure(abort_code = 37)]
    fun rejects_double_consume() {
        let mut scenario = test_scenario::begin(SENDER);
        init_world(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let dest = spk(0xBB);
        {
            let mut pool = test_scenario::take_shared<Pool>(&scenario);
            let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
            let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
            let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
            let admin = test_scenario::take_from_sender<AdminCap>(&scenario);

            prepare_processed(
                &admin, &mut pool, &mut utxo_set, &mut queue, &cap,
                dest, 50_000, 12_500, bytes(32, 0x44), 7, 100_000, 1_000,
                test_scenario::ctx(&mut scenario),
            );
            let sh = expected_sighash(dest, 50_000, bytes(32, 0x44), 7, 100_000, 1_000);
            ika_policy::approve_signing(
                &cap, &pool, &queue, &utxo_set, DWALLET_CAP, 0, 0, 1_000, sh,
                test_scenario::ctx(&mut scenario),
            );

            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_to_sender(&scenario, admin);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(utxo_set);
            test_scenario::return_shared(queue);
        };
        test_scenario::next_tx(&mut scenario, SENDER);

        let pool = test_scenario::take_shared<Pool>(&scenario);
        let queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<RedemptionCap>(&scenario);
        let mut approval = test_scenario::take_shared<SigningApproval>(&scenario);

        ika_policy::consume_approval(&cap, &pool, &queue, &mut approval, test_scenario::ctx(&mut scenario));
        ika_policy::consume_approval(&cap, &pool, &queue, &mut approval, test_scenario::ctx(&mut scenario));

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(queue);
        test_scenario::return_shared(approval);
        test_scenario::end(scenario);
    }
}
