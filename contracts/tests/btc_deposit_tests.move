#[test_only]
module utxopia::btc_deposit_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::object;
    use std::bcs;
    use std::hash;
    use utxopia::btc_light_client::{Self as lc, LightClient};
    use utxopia::btc_deposit::{Self, BtcDepositRegistry, UtxoSet};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::pool::{Self, Pool, AdminCap, AuditorCap};

    const SENDER: address = @0xA11CE;
    const AUDITOR: address = @0xAD17;
    const REGTEST: u8 = 3;
    const REGTEST_BITS: u32 = 0x207fffff;

    // Build a fresh, fully-initialized world; take shared objects in the next tx.
    fun setup(scenario: &mut test_scenario::Scenario) {
        let genesis = make_header(bytes(32, 0), bytes(32, 9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(scenario));
        pool::initialize(16, test_scenario::ctx(scenario));
        commitment_tree::initialize(test_scenario::ctx(scenario));
        btc_deposit::initialize_registry(test_scenario::ctx(scenario));
        btc_deposit::initialize_utxo_set(test_scenario::ctx(scenario));
    }

    // Pin the canonical companion objects to the pool (AdminCap-gated).
    fun bind(
        scenario: &test_scenario::Scenario,
        pool: &mut Pool,
        tree: &CommitmentTree,
        registry: &BtcDepositRegistry,
        utxo_set: &UtxoSet,
        light: &LightClient,
    ) {
        let admin = test_scenario::take_from_sender<AdminCap>(scenario);
        pool::set_commitment_tree_id(&admin, pool, object::id(tree));
        pool::set_btc_deposit_registry_id(&admin, pool, object::id(registry));
        pool::set_utxo_set_id(&admin, pool, object::id(utxo_set));
        pool::set_light_client_id(&admin, pool, object::id(light));
        pool::set_btc_pool_script(&admin, pool, p2tr(0x22));
        test_scenario::return_to_sender(scenario, admin);
    }

    #[test]
    fun completes_deposit_once() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        // deposit/sweep tx: credited P2TR (vout 0, 50_000) + deposit OP_RETURN (vout 1)
        let sweep_tx = build_deposit_tx(50_000, p2tr(0x22), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);

        // single-tx block whose merkle root IS the sweep txid
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit(
            &mut pool, &mut registry, &mut utxo_set, &mut tree,
            inclusion, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario),
        );

        assert!(commitment_tree::next_index(&tree) == 1, 0);
        assert!(commitment_tree::current_root(&tree) != commitment_tree::empty_root(), 1);
        assert!(btc_deposit::claimed_count(&registry) == 1, 2);
        assert!(btc_deposit::is_claimed(&registry, sweep_txid, 0), 3);
        assert!(btc_deposit::contains_utxo(&utxo_set, sweep_txid, 0), 4);
        assert!(pool::deposit_count(&pool) == 1, 5);
        assert!(pool::total_shielded(&pool) == 50_000, 6); // fee bps/service default 0

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 41)] // E_ALREADY_BOUND
    fun rejects_companion_rebinding() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let light = test_scenario::take_shared<LightClient>(&scenario);
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        // Re-binding any pinned companion must abort: swapping in a fresh
        // object would reset spent/claimed state.
        test_scenario::next_tx(&mut scenario, SENDER);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        pool::set_commitment_tree_id(&admin, &mut pool, object::id(&registry));
        abort 0
    }

    #[test, expected_failure(abort_code = 15)]
    fun rejects_duplicate_deposit() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        let sweep_tx = build_deposit_tx(50_000, p2tr(0x22), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inc1 = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit(&mut pool, &mut registry, &mut utxo_set, &mut tree, inc1, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario));

        // same outpoint again -> E_BTC_DEPOSIT_ALREADY_CLAIMED (15)
        let inc2 = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit(&mut pool, &mut registry, &mut utxo_set, &mut tree, inc2, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario));

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 40)]
    fun rejects_unbound_companions() {
        // Same happy-path flow but WITHOUT binding the canonical objects: complete_deposit
        // must fail closed (E_WRONG_OBJECT) rather than credit into an unpinned tree.
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        // (no bind() call on purpose)

        let sweep_tx = build_deposit_tx(50_000, p2tr(0x22), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit(&mut pool, &mut registry, &mut utxo_set, &mut tree, inclusion, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario)); // aborts 40

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 14)]
    fun rejects_deposit_to_wrong_pool_script() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        let sweep_tx = build_deposit_tx(50_000, p2tr(0x33), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit(&mut pool, &mut registry, &mut utxo_set, &mut tree, inclusion, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario));

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    // ===================== Finding 2: deposit attribution =====================

    // Build a separate (non-pool) deposit tx whose first spendable output carries
    // `deposit_value` sats to a P2TR address (fill byte 0x44).  The OP_RETURN
    // carries the pool + tree tag so the contract can locate it.
    fun build_separate_deposit_tx(
        pool: &Pool,
        tree: &CommitmentTree,
        deposit_value: u64,
    ): vector<u8> {
        // Input spends some coin (bytes32(0x55), vout 3) — arbitrary.
        let mut tx = le32(1);
        vector::append(&mut tx, vector[0x01u8]);    // 1 input
        vector::append(&mut tx, bytes(32, 0x55));   // prev_txid
        vector::append(&mut tx, le32(3));            // prev_vout
        vector::append(&mut tx, vector[0x00u8]);     // empty scriptSig
        vector::append(&mut tx, le32(0xffffffff));   // sequence
        vector::append(&mut tx, vector[0x02u8]);     // 2 outputs
        // vout 0: the value-bearing deposit output (NOT the pool script)
        vector::append(&mut tx, le64(deposit_value));
        let deposit_script = p2tr(0x44);
        vector::append(&mut tx, vector[(vector::length(&deposit_script) as u8)]);
        vector::append(&mut tx, deposit_script);
        // vout 1: OP_RETURN with pool tag + keys
        let or = op_return(pool, tree, 0x02, 0x01);
        vector::append(&mut tx, le64(0));
        vector::append(&mut tx, vector[(vector::length(&or) as u8)]);
        vector::append(&mut tx, or);
        vector::append(&mut tx, le32(0));            // locktime
        tx
    }

    // Build a sweep tx that spends the given deposit outpoint (deposit_txid, deposit_vout)
    // and pays `pool_output_value` sats to the pool script p2tr(0x22).
    fun build_sweep_tx(
        deposit_txid: vector<u8>,
        deposit_vout: u32,
        pool_output_value: u64,
    ): vector<u8> {
        let pool_script = p2tr(0x22);
        let mut tx = le32(1);
        vector::append(&mut tx, vector[0x01u8]);     // 1 input
        vector::append(&mut tx, deposit_txid);
        vector::append(&mut tx, le32(deposit_vout));
        vector::append(&mut tx, vector[0x00u8]);     // empty scriptSig
        vector::append(&mut tx, le32(0xffffffff));   // sequence
        vector::append(&mut tx, vector[0x01u8]);     // 1 output: pool
        vector::append(&mut tx, le64(pool_output_value));
        vector::append(&mut tx, vector[(vector::length(&pool_script) as u8)]);
        vector::append(&mut tx, pool_script);
        vector::append(&mut tx, le32(0));            // locktime
        tx
    }

    // Non-direct deposit: credited amount must equal the deposit tx's OWN output
    // value (30,000 sats), not an unrelated or larger pool-output value.
    #[test]
    fun credits_deposit_own_output_value_not_first_pool_output() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        let deposit_value: u64 = 30_000;
        let deposit_tx = build_separate_deposit_tx(&pool, &tree, deposit_value);
        let deposit_txid = lc::test_double_sha256(deposit_tx);
        // deposit output is vout 0 (first non-OP_RETURN output)
        let deposit_vout: u32 = 0;

        // Sweep pays EXACTLY deposit_value to the pool script — satisfies invariant.
        let sweep_tx = build_sweep_tx(deposit_txid, deposit_vout, deposit_value);
        let sweep_txid = lc::test_double_sha256(sweep_tx);

        // Mine the sweep tx into a block.
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit(
            &mut pool, &mut registry, &mut utxo_set, &mut tree,
            inclusion, sweep_tx, deposit_tx, false, vector[],
            test_scenario::ctx(&mut scenario),
        );

        // Credited shielded amount = deposit_value (fee bps/service default 0).
        assert!(pool::total_shielded(&pool) == (deposit_value as u128), 0);
        assert!(pool::deposit_count(&pool) == 1, 1);
        // Deduplicated on the deposit outpoint.
        assert!(btc_deposit::is_claimed(&registry, deposit_txid, deposit_vout), 2);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    // Conservative invariant: if the sweep's pool output value DIFFERS from the
    // deposit's output value, complete_deposit must abort (invalid_btc_deposit=14).
    #[test, expected_failure(abort_code = 14)]
    fun rejects_sweep_pool_output_mismatch() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        let deposit_value: u64 = 30_000;
        let deposit_tx = build_separate_deposit_tx(&pool, &tree, deposit_value);
        let deposit_txid = lc::test_double_sha256(deposit_tx);
        let deposit_vout: u32 = 0;

        // Sweep pool output carries 50,000 — does NOT match deposit's 30,000.
        // In a batched sweep this would over-credit the user.
        let sweep_tx = build_sweep_tx(deposit_txid, deposit_vout, 50_000);
        let sweep_txid = lc::test_double_sha256(sweep_tx);

        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        // must abort: invalid_btc_deposit (14)
        btc_deposit::complete_deposit(
            &mut pool, &mut registry, &mut utxo_set, &mut tree,
            inclusion, sweep_tx, deposit_tx, false, vector[],
            test_scenario::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    // ===================== permissioned pool tests (AuditorCap model) =====================

    fun setup_permissioned(scenario: &mut test_scenario::Scenario) {
        let genesis = make_header(bytes(32, 0), bytes(32, 9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(scenario));
        pool::initialize_permissioned(16, AUDITOR, test_scenario::ctx(scenario));
        commitment_tree::initialize(test_scenario::ctx(scenario));
        btc_deposit::initialize_registry(test_scenario::ctx(scenario));
        btc_deposit::initialize_utxo_set(test_scenario::ctx(scenario));
    }

    #[test]
    fun permissioned_deposit_via_auditor_succeeds() {
        let mut scenario = test_scenario::begin(SENDER);
        setup_permissioned(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        test_scenario::next_tx(&mut scenario, AUDITOR);
        let auditor_cap = test_scenario::take_from_sender<AuditorCap>(&scenario);

        test_scenario::next_tx(&mut scenario, SENDER);
        let sweep_tx = build_deposit_tx(50_000, p2tr(0x22), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        btc_deposit::complete_deposit_permissioned(
            &auditor_cap,
            &mut pool, &mut registry, &mut utxo_set, &mut tree,
            inclusion, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario),
        );

        assert!(commitment_tree::next_index(&tree) == 1, 0);
        assert!(commitment_tree::current_root(&tree) != commitment_tree::empty_root(), 1);
        assert!(btc_deposit::claimed_count(&registry) == 1, 2);
        assert!(pool::deposit_count(&pool) == 1, 3);

        test_scenario::return_to_address(AUDITOR, auditor_cap);
        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 54)]
    fun permissioned_deposit_rejects_when_frozen() {
        let mut scenario = test_scenario::begin(SENDER);
        setup_permissioned(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        test_scenario::next_tx(&mut scenario, AUDITOR);
        let auditor_cap = test_scenario::take_from_sender<AuditorCap>(&scenario);
        pool::set_auditor_frozen(&auditor_cap, &mut pool, true);

        test_scenario::next_tx(&mut scenario, SENDER);
        let sweep_tx = build_deposit_tx(50_000, p2tr(0x22), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        // frozen -> auditor_frozen (54)
        btc_deposit::complete_deposit_permissioned(
            &auditor_cap,
            &mut pool, &mut registry, &mut utxo_set, &mut tree,
            inclusion, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_to_sender(&scenario, auditor_cap);
        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 56)]
    fun permissioned_deposit_rejects_public_entry() {
        let mut scenario = test_scenario::begin(SENDER);
        setup_permissioned(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);
        let mut utxo_set = test_scenario::take_shared<UtxoSet>(&scenario);
        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        bind(&scenario, &mut pool, &tree, &registry, &utxo_set, &light);

        test_scenario::next_tx(&mut scenario, SENDER);
        let sweep_tx = build_deposit_tx(50_000, p2tr(0x22), op_return(&pool, &tree, 0x02, 0x01));
        let sweep_txid = lc::test_double_sha256(sweep_tx);
        let g = lc::tip_hash(&light);
        let block = make_header(g, sweep_txid, 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, block, &clk);
        let block_hash = lc::test_double_sha256(block);

        let inclusion = lc::verify_tx_inclusion(&light, block_hash, sweep_txid, 0, vector[], 0);
        // permissioned pool called via public entry -> not_permissioned (56)
        btc_deposit::complete_deposit(
            &mut pool, &mut registry, &mut utxo_set, &mut tree,
            inclusion, sweep_tx, vector[], true, vector[], test_scenario::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(utxo_set);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    // ===================== helpers =====================

    fun make_header(prev: vector<u8>, merkle: vector<u8>, ts: u32, bits: u32, nonce: u32): vector<u8> {
        let mut h = le32(1);
        vector::append(&mut h, prev);
        vector::append(&mut h, merkle);
        vector::append(&mut h, le32(ts));
        vector::append(&mut h, le32(bits));
        vector::append(&mut h, le32(nonce));
        h
    }

    /// One-input, two-output non-SegWit tx. Input spends (bytes32(0x11), vout 7).
    fun build_deposit_tx(v0: u64, s0: vector<u8>, s1: vector<u8>): vector<u8> {
        let mut tx = le32(1);
        vector::append(&mut tx, vector[0x01u8]);   // 1 input
        vector::append(&mut tx, bytes(32, 0x11));  // prev_txid
        vector::append(&mut tx, le32(7));           // prev_vout
        vector::append(&mut tx, vector[0x00u8]);    // empty scriptSig
        vector::append(&mut tx, le32(0xffffffff));  // sequence
        vector::append(&mut tx, vector[0x02u8]);    // 2 outputs
        vector::append(&mut tx, le64(v0));
        vector::append(&mut tx, vector[(vector::length(&s0) as u8)]);
        vector::append(&mut tx, s0);
        vector::append(&mut tx, le64(0));           // OP_RETURN output value 0
        vector::append(&mut tx, vector[(vector::length(&s1) as u8)]);
        vector::append(&mut tx, s1);
        vector::append(&mut tx, le32(0));           // locktime
        tx
    }

    fun le32(v: u32): vector<u8> {
        vector[((v & 0xff) as u8), (((v >> 8) & 0xff) as u8), (((v >> 16) & 0xff) as u8), (((v >> 24) & 0xff) as u8)]
    }

    fun le64(v: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 8) { vector::push_back(&mut out, (((v >> ((8 * i) as u8)) & 0xff) as u8)); i = i + 1; };
        out
    }

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    fun p2tr(fill: u8): vector<u8> {
        let mut s = vector[0x51u8, 0x20u8];
        vector::append(&mut s, bytes(32, fill));
        s
    }

    fun op_return(pool: &Pool, tree: &CommitmentTree, ephemeral_fill: u8, note_public_key_fill: u8): vector<u8> {
        let mut s = vector[0x6au8, 0x49u8, 0x63u8];
        vector::append(&mut s, expected_pool_tag(pool, tree));
        vector::append(&mut s, bytes(32, ephemeral_fill));
        vector::append(&mut s, bytes(32, note_public_key_fill));
        s
    }

    fun expected_pool_tag(pool: &Pool, _tree: &CommitmentTree): vector<u8> {
        // Pool-only tag (no tree component) — matches the on-chain change for audit CRITICAL #0.
        let mut data = b"UTXOPIA_SUI";
        vector::append(&mut data, bcs::to_bytes(&pool::pool_id(pool)));
        btc_slice(&hash::sha2_256(data), 0, 8)
    }

    fun btc_slice(data: &vector<u8>, start: u64, len: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < len) {
            vector::push_back(&mut out, *vector::borrow(data, start + i));
            i = i + 1;
        };
        out
    }

    // Cross-language lock with the SDK's `computeSuiDepositPoolTag` (audit CRITICAL #0,
    // pool-only deposit tag). This is the exact formula `expected_pool_tag` uses, pinned
    // for pool id 0x01*32. The TS test `taproot.test.ts > computeSuiDepositPoolTag` asserts
    // the same vector. `bcs::to_bytes(&address)` is the raw 32 bytes, so the 0x01*32 input
    // models a pool whose object id is 0x01*32.
    #[test]
    fun pool_tag_matches_sdk_vector() {
        let mut data = b"UTXOPIA_SUI";
        vector::append(&mut data, bytes(32, 0x01));
        let tag = btc_slice(&hash::sha2_256(data), 0, 8);
        assert!(tag == vector[191u8, 2u8, 13u8, 108u8, 129u8, 152u8, 4u8, 28u8], 0);
    }
}
