#[test_only]
module utxopia::bitcoin_tests {
    use utxopia::bitcoin as btc;

    // ===================== varint =====================

    #[test]
    fun u_varint_cases() {
        let (v, o) = btc::test_read_varint(vector[0x00], 0);
        assert!(v == 0 && o == 1, 0);
        let (v, o) = btc::test_read_varint(vector[0xfc], 0);
        assert!(v == 252 && o == 1, 1);
        let (v, o) = btc::test_read_varint(vector[0xfd, 0x00, 0x01], 0);
        assert!(v == 256 && o == 3, 2);
        let (v, o) = btc::test_read_varint(vector[0xfe, 0x01, 0x00, 0x00, 0x00], 0);
        assert!(v == 1 && o == 5, 3);
        let (v, o) = btc::test_read_varint(vector[0xff, 0x01, 0, 0, 0, 0, 0, 0, 0], 0);
        assert!(v == 1 && o == 9, 4);
    }

    #[test, expected_failure(abort_code = 29)]
    fun u_varint_truncated() {
        // 0xfd announces 2 more bytes but only 1 is present -> E_TX_TRUNCATED
        btc::test_read_varint(vector[0xfd, 0x00], 0);
    }

    // ===================== OP_RETURN =====================

    #[test]
    fun u_op_return_direct_push() {
        let mut script = vector[0x6au8, 0x49u8, 0x63u8];
        vector::append(&mut script, bytes(8, 0xCC));
        vector::append(&mut script, bytes(32, 0xAA));
        vector::append(&mut script, bytes(32, 0xBB));
        let (ok, tag, eph, npk) = btc::parse_deposit_op_return(&script);
        assert!(ok, 0);
        assert!(tag == bytes(8, 0xCC), 1);
        assert!(eph == bytes(32, 0xAA), 2);
        assert!(npk == bytes(32, 0xBB), 3);
    }

    #[test]
    fun u_op_return_pushdata1() {
        let mut script = vector[0x6au8, 0x4cu8, 0x49u8, 0x63u8];
        vector::append(&mut script, bytes(8, 0xCC));
        vector::append(&mut script, bytes(32, 0xCC));
        vector::append(&mut script, bytes(32, 0xDD));
        let (ok, tag, eph, npk) = btc::parse_deposit_op_return(&script);
        assert!(ok, 0);
        assert!(tag == bytes(8, 0xCC), 1);
        assert!(eph == bytes(32, 0xCC), 2);
        assert!(npk == bytes(32, 0xDD), 3);
    }

    #[test]
    fun u_op_return_wrong_size() {
        // 32-byte commitment OP_RETURN must NOT match the compact deposit layout
        let mut script = vector[0x6au8, 0x20u8];
        vector::append(&mut script, bytes(32, 0xEE));
        let (ok, _tag, _eph, _npk) = btc::parse_deposit_op_return(&script);
        assert!(!ok, 0);
    }

    // ===================== output / input selection =====================

    #[test]
    fun u_find_outputs_and_op_return() {
        // credited output at vout 0 (P2TR), deposit OP_RETURN at vout 1
        let tx = build_tx(50_000, p2tr(0x22), 0, op_return(0xAA, 0xBB));

        let (ok, out, vout) = btc::find_deposit_output_with_vout(&tx);
        assert!(ok, 0);
        assert!(vout == 0, 1);
        assert!(btc::output_value(&out) == 50_000, 2);

        let (ok2, _tag, eph, npk) = btc::find_deposit_op_return(&tx);
        assert!(ok2, 3);
        assert!(eph == bytes(32, 0xAA), 4);
        assert!(npk == bytes(32, 0xBB), 5);

        let (ok3, _o3, vout3) = btc::find_output_by_script(&tx, &p2tr(0x22));
        assert!(ok3 && vout3 == 0, 6);
    }

    #[test]
    fun u_op_return_first_credited_is_vout1() {
        // OP_RETURN at vout 0, credited output at vout 1 — vout must be the absolute index
        let tx = build_tx(0, op_return(0x11, 0x22), 70_000, p2tr(0x33));
        let (ok, out, vout) = btc::find_deposit_output_with_vout(&tx);
        assert!(ok, 0);
        assert!(vout == 1, 1);
        assert!(btc::output_value(&out) == 70_000, 2);
    }

    #[test]
    fun u_input_prev_outpoint_linkage() {
        // build_tx hardcodes a single input spending (bytes32(0x11), vout 7)
        let tx = build_tx(50_000, p2tr(0x22), 0, op_return(0xAA, 0xBB));
        assert!(btc::has_input_with_prev_outpoint(&tx, &bytes(32, 0x11), 7), 0);
        // hardening over Solana: matching txid but WRONG vout must NOT link
        assert!(!btc::has_input_with_prev_outpoint(&tx, &bytes(32, 0x11), 8), 1);
        assert!(!btc::has_input_with_prev_outpoint(&tx, &bytes(32, 0x99), 7), 2);
    }

    #[test, expected_failure(abort_code = 29)]
    fun u_truncated_tx_aborts() {
        let tx = build_tx(50_000, p2tr(0x22), 0, op_return(0xAA, 0xBB));
        let truncated = btc_slice(&tx, 0, 12); // valid-length prefix, but parsing runs past end
        btc::find_deposit_output_with_vout(&truncated);
    }

    // ===================== helpers =====================

    fun le32(v: u32): vector<u8> {
        vector[
            ((v & 0xff) as u8),
            (((v >> 8) & 0xff) as u8),
            (((v >> 16) & 0xff) as u8),
            (((v >> 24) & 0xff) as u8),
        ]
    }

    fun le64(v: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 8) {
            vector::push_back(&mut out, (((v >> ((8 * i) as u8)) & 0xff) as u8));
            i = i + 1;
        };
        out
    }

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    fun p2tr(fill: u8): vector<u8> {
        let mut s = vector[0x51u8, 0x20u8]; // OP_1 PUSH32
        vector::append(&mut s, bytes(32, fill));
        s
    }

    fun op_return(eph_fill: u8, npk_fill: u8): vector<u8> {
        let mut s = vector[0x6au8, 0x49u8, 0x63u8];
        vector::append(&mut s, bytes(8, 0xCC));
        vector::append(&mut s, bytes(32, eph_fill));
        vector::append(&mut s, bytes(32, npk_fill));
        s
    }

    /// One-input, two-output legacy tx. Input spends (bytes32(0x11), vout 7).
    fun build_tx(v0: u64, s0: vector<u8>, v1: u64, s1: vector<u8>): vector<u8> {
        let mut tx = le32(1); // version
        vector::append(&mut tx, vector[0x01u8]); // 1 input
        vector::append(&mut tx, bytes(32, 0x11)); // prev_txid
        vector::append(&mut tx, le32(7));          // prev_vout
        vector::append(&mut tx, vector[0x00u8]);   // empty scriptSig
        vector::append(&mut tx, le32(0xffffffff)); // sequence
        vector::append(&mut tx, vector[0x02u8]);   // 2 outputs
        vector::append(&mut tx, le64(v0));
        vector::append(&mut tx, vector[(vector::length(&s0) as u8)]);
        vector::append(&mut tx, s0);
        vector::append(&mut tx, le64(v1));
        vector::append(&mut tx, vector[(vector::length(&s1) as u8)]);
        vector::append(&mut tx, s1);
        vector::append(&mut tx, le32(0)); // locktime
        tx
    }

    fun btc_slice(data: &vector<u8>, start: u64, len: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < len) { vector::push_back(&mut out, *vector::borrow(data, start + i)); i = i + 1; };
        out
    }
}
