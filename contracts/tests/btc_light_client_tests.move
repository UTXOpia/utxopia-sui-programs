#[test_only]
module utxopia::btc_light_client_tests {
    use sui::test_scenario;
    use sui::clock;
    use utxopia::btc_light_client::{Self as lc, LightClient, LightClientAdminCap};

    const SENDER: address = @0xA11CE;
    const REGTEST: u8 = 2;
    const REGTEST_BITS: u32 = 0x207fffff;

    // ===================== Unit: PoW / target / work / retarget =====================

    #[test]
    fun u_target_from_bits_max() {
        // bits 0x1d00ffff decodes to the difficulty-1 / max mainnet target.
        assert!(lc::test_target_from_bits(0x1d00ffff) == lc::test_max_target(), 0);
    }

    #[test]
    fun u_work_from_bits_genesis() {
        // Difficulty-1 cumulative work == 0x100010001 == 4295032833 (Bitcoin Core GetBlockProof).
        assert!(lc::test_work_from_bits(0x1d00ffff) == 4295032833, 0);
    }

    #[test]
    fun u_bits_target_roundtrip() {
        assert!(lc::test_bits_from_target(lc::test_target_from_bits(0x1d00ffff)) == 0x1d00ffff, 0);
        assert!(lc::test_bits_from_target(lc::test_target_from_bits(0x1b0404cb)) == 0x1b0404cb, 1);
        // sign-bit (0x00800000) branch: a target whose top byte is >= 0x80 must gain a byte.
        assert!(lc::test_target_from_bits(lc::test_bits_from_target(0x800000)) == 0x800000, 2);
    }

    #[test]
    fun u_double_sha256_genesis() {
        // The Bitcoin genesis 80-byte header double-SHA256s to the genesis block hash
        // (internal/little-endian byte order).
        let header = x"0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c";
        let expected = x"6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000";
        assert!(lc::test_double_sha256(header) == expected, 0);
    }

    #[test]
    fun u_hash_meets_target() {
        let genesis_hash = x"6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000";
        // genesis PoW is valid: hash <= max target
        assert!(lc::test_hash_meets_target(genesis_hash, lc::test_max_target()), 0);
        // an all-ones hash (max value) exceeds the target
        let max_hash = x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        assert!(!lc::test_hash_meets_target(max_hash, lc::test_max_target()), 1);
    }

    #[test]
    fun u_wrapping_sub() {
        assert!(lc::test_wrapping_sub_u32(10, 5) == 5, 0);
        assert!(lc::test_wrapping_sub_u32(5, 10) == 4294967291, 1); // 0xFFFFFFFB
        assert!(lc::test_wrapping_sub_u32(0, 1) == 4294967295, 2);  // 0xFFFFFFFF
    }

    #[test]
    fun u_calculate_new_bits() {
        // exactly the target timespan => difficulty unchanged
        assert!(lc::test_calculate_new_bits(0x1d00ffff, 1209600) == 0x1d00ffff, 0);
        // tiny timespan clamps to TS/4 => target/4 (difficulty up)
        let expected_low = lc::test_bits_from_target(lc::test_max_target() / 4);
        assert!(lc::test_calculate_new_bits(0x1d00ffff, 1) == expected_low, 1);
        // huge timespan clamps to TS*4 => target*4 capped at MAX_TARGET => unchanged bits
        assert!(lc::test_calculate_new_bits(0x1d00ffff, 4294967295) == 0x1d00ffff, 2);
    }

    // ===================== Integration: submit / reorg / inclusion =====================

    #[test]
    fun i_init_and_submit() {
        let mut scenario = test_scenario::begin(SENDER);
        let genesis = make_header(bytes32(0), bytes32(9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        assert!(lc::tip_height(&light) == 100, 0);
        let g = lc::tip_hash(&light);

        let child = make_header(g, bytes32(10), 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, child, &clk);

        assert!(lc::tip_height(&light) == 101, 1);
        assert!(lc::tip_hash(&light) == lc::test_double_sha256(child), 2);
        assert!(lc::confirmations(&light, lc::test_double_sha256(child)) == 1, 3);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test]
    fun i_reorg_by_chainwork() {
        let mut scenario = test_scenario::begin(SENDER);
        let genesis = make_header(bytes32(0), bytes32(9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let g = lc::tip_hash(&light);

        // chain A: 2 blocks
        let a1 = make_header(g, bytes32(11), 1001, REGTEST_BITS, 1);
        let a1h = lc::test_double_sha256(a1);
        let a2 = make_header(a1h, bytes32(12), 1002, REGTEST_BITS, 2);
        let a2h = lc::test_double_sha256(a2);
        let mut batch_a = a1;
        vector::append(&mut batch_a, a2);
        lc::submit_headers(&mut light, batch_a, &clk);
        assert!(lc::tip_height(&light) == 102, 0);
        assert!(lc::tip_hash(&light) == a2h, 1);

        // fork B: 3 blocks from genesis => more cumulative work => reorg
        let b1 = make_header(g, bytes32(21), 1001, REGTEST_BITS, 11);
        let b1h = lc::test_double_sha256(b1);
        let b2 = make_header(b1h, bytes32(22), 1002, REGTEST_BITS, 12);
        let b2h = lc::test_double_sha256(b2);
        let b3 = make_header(b2h, bytes32(23), 1003, REGTEST_BITS, 13);
        let b3h = lc::test_double_sha256(b3);
        let mut batch_b = b1;
        vector::append(&mut batch_b, b2);
        vector::append(&mut batch_b, b3);
        lc::submit_headers(&mut light, batch_b, &clk);

        assert!(lc::tip_height(&light) == 103, 2);
        assert!(lc::tip_hash(&light) == b3h, 3);
        // A2 is orphaned: no longer canonical at its height
        assert!(lc::confirmations(&light, a2h) == 0, 4);
        assert!(lc::confirmations(&light, b3h) == 1, 5);
        assert!(lc::confirmations(&light, g) == 4, 6); // genesis at 100, tip 103

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test]
    fun i_verify_single_tx_inclusion() {
        let mut scenario = test_scenario::begin(SENDER);
        let genesis = make_header(bytes32(0), bytes32(9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let g = lc::tip_hash(&light);

        // single-tx block: merkle_root == txid
        let txid = bytes32(42);
        let blk = make_header(g, txid, 1001, REGTEST_BITS, 7);
        let blkh = lc::test_double_sha256(blk);
        lc::submit_headers(&mut light, blk, &clk);

        let v = lc::verify_tx_inclusion(&light, blkh, txid, 0, vector[], 0);
        let (out_txid, out_block, out_height, out_root, out_index) = lc::consume_inclusion(v);
        assert!(out_txid == txid, 0);
        assert!(out_block == blkh, 1);
        assert!(out_height == 101, 2);
        assert!(out_root == txid, 3);
        assert!(out_index == 0, 4);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 26)]
    fun i_paused_rejects_submit() {
        let mut scenario = test_scenario::begin(SENDER);
        let genesis = make_header(bytes32(0), bytes32(9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let cap = test_scenario::take_from_sender<LightClientAdminCap>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let g = lc::tip_hash(&light);

        lc::set_paused(&cap, &mut light, true);
        let child = make_header(g, bytes32(10), 1001, REGTEST_BITS, 1);
        lc::submit_headers(&mut light, child, &clk); // aborts lc_paused (26)

        clock::destroy_for_testing(clk);
        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 19)]
    fun i_continuity_break_rejects() {
        let mut scenario = test_scenario::begin(SENDER);
        let genesis = make_header(bytes32(0), bytes32(9), 1000, REGTEST_BITS, 0);
        lc::initialize(REGTEST, genesis, 100, 1000, REGTEST_BITS, 1000, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut light = test_scenario::take_shared<LightClient>(&scenario);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let g = lc::tip_hash(&light);

        // batch where the 2nd header does not build on the 1st
        let a1 = make_header(g, bytes32(11), 1001, REGTEST_BITS, 1);
        let bad = make_header(bytes32(99), bytes32(12), 1002, REGTEST_BITS, 2);
        let mut batch = a1;
        vector::append(&mut batch, bad);
        lc::submit_headers(&mut light, batch, &clk); // aborts header_prev_mismatch (19)

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(light);
        test_scenario::end(scenario);
    }

    // ===================== helpers =====================

    fun make_header(
        prev: vector<u8>,
        merkle: vector<u8>,
        timestamp: u32,
        bits: u32,
        nonce: u32,
    ): vector<u8> {
        let mut h = u32_to_le(1); // version
        vector::append(&mut h, prev);
        vector::append(&mut h, merkle);
        vector::append(&mut h, u32_to_le(timestamp));
        vector::append(&mut h, u32_to_le(bits));
        vector::append(&mut h, u32_to_le(nonce));
        h
    }

    fun u32_to_le(v: u32): vector<u8> {
        vector[
            ((v & 0xff) as u8),
            (((v >> 8) & 0xff) as u8),
            (((v >> 16) & 0xff) as u8),
            (((v >> 24) & 0xff) as u8),
        ]
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
}
