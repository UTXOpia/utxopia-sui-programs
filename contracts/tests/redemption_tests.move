#[test_only]
module utxopia::redemption_tests {
    use sui::object;
    use sui::test_scenario;
    use utxopia::bitcoin;
    use utxopia::btc_light_client;
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

    fun public_inputs_with_outputs(
        bound_params_hash: vector<u8>,
        nullifier_in: vector<u8>,
        commitments_out: vector<vector<u8>>,
    ): vector<u8> {
        let mut out = bytes(32, 0);
        vector::append(&mut out, bound_params_hash);
        vector::append(&mut out, nullifier_in);
        let mut i = 0;
        while (i < commitments_out.length()) {
            vector::append(&mut out, *commitments_out.borrow(i));
            i = i + 1;
        };
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
    fun redeem_rejects_mutated_stealth_data() {
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
        let amount = 50_000;
        let change_commitment = bytes(32, 0x03);
        let redeem_commitment = redemption::test_public_redeem_commitment(&pool, amount);
        let commitments_out = vector[change_commitment, redeem_commitment];
        let submitted_commitments_out = vector[bytes(32, 0x03), redemption::test_public_redeem_commitment(&pool, amount)];
        let bound = redemption::test_redeem_bound_params_hash_with_stealth(
            vector[script],
            vector[bytes(72, 0x11)],
        );

        redemption::redeem(
            &mut pool,
            &mut tree,
            &mut nullifiers,
            &vk_registry,
            &mut queue,
            1,
            2,
            1,
            bytes(32, 0xaa),
            public_inputs_with_outputs(bound, bytes(32, 0x01), commitments_out),
            vector[],
            vector[bytes(32, 0x01)],
            submitted_commitments_out,
            vector[bytes(34, 0x51)],
            vector[amount],
            vector[bytes(72, 0x12)],
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

    // ---- complete_redemption coverage (findings #1 change-theft, #3 extra-input) ----

    const LC_ADDR: address = @0x11C;
    const POOL_SCRIPT: vector<u8> = b"pool-change-script----"; // 22 bytes

    fun le_u32(v: u32): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 4) { vector::push_back(&mut out, (((v >> ((8 * i) as u8)) & 0xff) as u8)); i = i + 1; };
        out
    }

    fun le_u64(v: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 8) { vector::push_back(&mut out, (((v >> ((8 * i) as u8)) & 0xff) as u8)); i = i + 1; };
        out
    }

    // Builds a minimal non-segwit Bitcoin tx. Scripts must be < 0xfd bytes.
    fun build_tx(
        in_txids: vector<vector<u8>>,
        in_vouts: vector<u32>,
        out_values: vector<u64>,
        out_scripts: vector<vector<u8>>,
    ): vector<u8> {
        let mut tx = vector[0x01, 0x00, 0x00, 0x00]; // version
        vector::push_back(&mut tx, (vector::length(&in_txids) as u8)); // input count varint
        let mut i = 0u64;
        while (i < vector::length(&in_txids)) {
            vector::append(&mut tx, *vector::borrow(&in_txids, i)); // prev txid (32)
            vector::append(&mut tx, le_u32(*vector::borrow(&in_vouts, i))); // prev vout
            vector::push_back(&mut tx, 0x00); // empty scriptSig
            vector::append(&mut tx, vector[0xff, 0xff, 0xff, 0xff]); // sequence
            i = i + 1;
        };
        vector::push_back(&mut tx, (vector::length(&out_values) as u8)); // output count varint
        let mut j = 0u64;
        while (j < vector::length(&out_values)) {
            vector::append(&mut tx, le_u64(*vector::borrow(&out_values, j))); // value
            let script = *vector::borrow(&out_scripts, j);
            vector::push_back(&mut tx, (vector::length(&script) as u8)); // script len varint
            vector::append(&mut tx, script);
            j = j + 1;
        };
        vector::append(&mut tx, vector[0x00, 0x00, 0x00, 0x00]); // locktime
        tx
    }

    // Stand up a pool (all companion ids + light client + change script bound) with one
    // 100k-sat reserved UTXO behind a redemption for 50k. Takes AdminCap exactly once.
    fun setup_processing(
        scenario: &mut test_scenario::Scenario,
        pool: &mut Pool,
        tree: &CommitmentTree,
        utxo_set: &mut UtxoSet,
        nullifiers: &NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
        queue: &mut RedemptionQueue,
        cap: &utxopia::redemption::RedemptionCap,
        btc_script: vector<u8>,
    ) {
        let admin = test_scenario::take_from_sender<AdminCap>(scenario);
        pool::set_commitment_tree_id(&admin, pool, object::id(tree));
        pool::set_utxo_set_id(&admin, pool, object::id(utxo_set));
        pool::set_nullifier_registry_id(&admin, pool, object::id(nullifiers));
        pool::set_vk_registry_id(&admin, pool, object::id(vk_registry));
        pool::set_light_client_id(&admin, pool, object::id_from_address(LC_ADDR));
        pool::set_btc_pool_script(&admin, pool, POOL_SCRIPT);
        test_scenario::return_to_sender(scenario, admin);

        btc_deposit::test_add_utxo(utxo_set, pool::pool_id(pool), bytes(32, 0x44), 7, 100_000, test_scenario::ctx(scenario));
        redemption::test_request_redemption(pool, queue, btc_script, 50_000, 2_000, test_scenario::ctx(scenario));
        redemption::mark_processing(cap, pool, utxo_set, queue, 0, vector[bytes(32, 0x44)], vector[7], 1_000);
    }

    #[test]
    fun complete_redemption_returns_change_to_pool() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<utxopia::redemption::RedemptionCap>(&scenario);

        let btc_script = bytes(34, 0x51);
        setup_processing(&mut scenario, &mut pool, &tree, &mut utxo_set, &nullifiers, &vk_registry, &mut queue, &cap, btc_script);

        // 50k to redeemer + 49k change to pool => 1k miner fee (<= 2k cap).
        let raw_tx = build_tx(
            vector[bytes(32, 0x44)],
            vector[7],
            vector[50_000, 49_000],
            vector[btc_script, POOL_SCRIPT],
        );
        let txid = bitcoin::double_sha256(&raw_tx);
        let inclusion = btc_light_client::test_new_inclusion(object::id_from_address(LC_ADDR), txid);

        redemption::complete_redemption(&cap, &pool, &mut utxo_set, &mut queue, 0, inclusion, raw_tx, test_scenario::ctx(&mut scenario));

        // Reserved input consumed, pool change (output index 1) recorded.
        assert!(!btc_deposit::contains_utxo(&utxo_set, bytes(32, 0x44), 7), 0);
        assert!(btc_deposit::contains_utxo(&utxo_set, txid, 1), 1);

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
    fun complete_redemption_rejects_change_to_attacker() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<utxopia::redemption::RedemptionCap>(&scenario);

        let btc_script = bytes(34, 0x51);
        setup_processing(&mut scenario, &mut pool, &tree, &mut utxo_set, &nullifiers, &vk_registry, &mut queue, &cap, btc_script);

        // Change routed to an attacker script instead of the pool => must abort.
        let raw_tx = build_tx(
            vector[bytes(32, 0x44)],
            vector[7],
            vector[50_000, 49_000],
            vector[btc_script, bytes(22, 0xee)],
        );
        let txid = bitcoin::double_sha256(&raw_tx);
        let inclusion = btc_light_client::test_new_inclusion(object::id_from_address(LC_ADDR), txid);

        redemption::complete_redemption(&cap, &pool, &mut utxo_set, &mut queue, 0, inclusion, raw_tx, test_scenario::ctx(&mut scenario));

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
    fun complete_redemption_rejects_extra_input() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut queue = test_scenario::take_shared<RedemptionQueue>(&scenario);
        let cap = test_scenario::take_from_sender<utxopia::redemption::RedemptionCap>(&scenario);

        let btc_script = bytes(34, 0x51);
        setup_processing(&mut scenario, &mut pool, &tree, &mut utxo_set, &nullifiers, &vk_registry, &mut queue, &cap, btc_script);

        // Tx spends an extra (unreserved) input beyond the single reserved UTXO => must abort.
        let raw_tx = build_tx(
            vector[bytes(32, 0x44), bytes(32, 0x55)],
            vector[7, 8],
            vector[50_000, 49_000],
            vector[btc_script, POOL_SCRIPT],
        );
        let txid = bitcoin::double_sha256(&raw_tx);
        let inclusion = btc_light_client::test_new_inclusion(object::id_from_address(LC_ADDR), txid);

        redemption::complete_redemption(&cap, &pool, &mut utxo_set, &mut queue, 0, inclusion, raw_tx, test_scenario::ctx(&mut scenario));

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
