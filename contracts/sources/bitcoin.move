/// Bitcoin transaction parser (Move port of `utils/bitcoin.rs`).
///
/// Pure, stateless helpers shared by the SPV/deposit path: varint + LE readers, output
/// and input iteration, deposit OP_RETURN extraction (v1 header + pool tag + note fields),
/// credited-output selection, and prev-outpoint linkage. SHA256/Merkle live in the light
/// client (module 01); Poseidon lives in the commitment tree (module 03). This module does
/// no hashing and no field math — only structural parsing of raw legacy-serialized txs.
module utxopia::bitcoin {
    use std::hash;
    use utxopia::errors;

    const OP_RETURN: u8 = 0x6a;
    const DEPOSIT_OP_RETURN_SIZE: u64 = 73; // header(1) + pool_tag(8) + ephemeral(32) + npk(32)
    const DEPOSIT_HEADER_SUI_MAINNET: u8 = 0x60;
    const DEPOSIT_HEADER_SUI_TESTNET4: u8 = 0x62;
    const DEPOSIT_HEADER_SUI_REGTEST: u8 = 0x63;
    const MAX_INPUTS: u64 = 8_000;
    const MAX_OUTPUTS: u64 = 8_000;
    const MAX_TX_BYTES: u64 = 400_000;
    const MIN_TX_BYTES: u64 = 10;

    public struct TxOutput has copy, drop { value: u64, script_pubkey: vector<u8> }
    public struct TxInput has copy, drop { prev_txid: vector<u8>, prev_vout: u32 }

    // --- accessors ---
    public fun output_value(o: &TxOutput): u64 { o.value }
    public fun output_script(o: &TxOutput): vector<u8> { o.script_pubkey }
    public fun input_prev_txid(i: &TxInput): vector<u8> { i.prev_txid }
    public fun input_prev_vout(i: &TxInput): u32 { i.prev_vout }

    // ---------------------------------------------------------------------
    // Low-level readers
    // ---------------------------------------------------------------------

    fun ensure(data: &vector<u8>, off: u64, need: u64) {
        assert!(off + need <= vector::length(data), errors::tx_truncated());
    }

    /// Bitcoin double-SHA256 (internal byte order). Binds a raw tx to its proven txid.
    public(package) fun double_sha256(data: &vector<u8>): vector<u8> {
        hash::sha2_256(hash::sha2_256(*data))
    }

    public(package) fun read_u32_le(data: &vector<u8>, off: u64): u32 {
        ensure(data, off, 4);
        (*vector::borrow(data, off) as u32)
            | ((*vector::borrow(data, off + 1) as u32) << 8)
            | ((*vector::borrow(data, off + 2) as u32) << 16)
            | ((*vector::borrow(data, off + 3) as u32) << 24)
    }

    public(package) fun read_u64_le(data: &vector<u8>, off: u64): u64 {
        ensure(data, off, 8);
        let mut acc = 0u64;
        let mut i = 0u64;
        while (i < 8) {
            acc = acc | ((*vector::borrow(data, off + i) as u64) << ((8 * i) as u8));
            i = i + 1;
        };
        acc
    }

    fun read_u16_le(data: &vector<u8>, off: u64): u64 {
        ensure(data, off, 2);
        (*vector::borrow(data, off) as u64) | ((*vector::borrow(data, off + 1) as u64) << 8)
    }

    /// CompactSize varint. Returns (value, new_offset). Non-minimal encodings are accepted
    /// (matching Bitcoin consensus / Solana `read_varint`); bounds are checked.
    public(package) fun read_varint(data: &vector<u8>, off: u64): (u64, u64) {
        ensure(data, off, 1);
        let first = *vector::borrow(data, off);
        if (first < 0xfd) {
            ((first as u64), off + 1)
        } else if (first == 0xfd) {
            (read_u16_le(data, off + 1), off + 3)
        } else if (first == 0xfe) {
            ((read_u32_le(data, off + 1) as u64), off + 5)
        } else {
            (read_u64_le(data, off + 1), off + 9)
        }
    }

    public(package) fun slice(data: &vector<u8>, start: u64, len: u64): vector<u8> {
        ensure(data, start, len);
        let mut out = vector[];
        let mut i = 0u64;
        while (i < len) {
            vector::push_back(&mut out, *vector::borrow(data, start + i));
            i = i + 1;
        };
        out
    }

    // ---------------------------------------------------------------------
    // Structural parse
    // ---------------------------------------------------------------------

    /// Returns (output_count, offset_at_first_output) after skipping version, an optional
    /// segwit marker+flag, and all inputs. Aborts E_TX_TRUNCATED on any out-of-bounds read.
    fun outputs_cursor(raw_tx: &vector<u8>): (u64, u64) {
        let len = vector::length(raw_tx);
        assert!(len >= MIN_TX_BYTES && len <= MAX_TX_BYTES, errors::invalid_raw_tx());

        let mut off = 4; // version
        // segwit marker + flag (0x00 0x01)
        if (len >= off + 2 && *vector::borrow(raw_tx, off) == 0x00 && *vector::borrow(raw_tx, off + 1) == 0x01) {
            off = off + 2;
        };

        let (in_count, off1) = read_varint(raw_tx, off);
        off = off1;
        assert!(in_count <= MAX_INPUTS, errors::invalid_raw_tx());

        let mut k = 0;
        while (k < in_count) {
            ensure(raw_tx, off, 36); // prev outpoint (txid 32 + vout 4)
            off = off + 36;
            let (script_len, off2) = read_varint(raw_tx, off);
            off = off2;
            ensure(raw_tx, off, script_len + 4); // scriptSig + sequence
            off = off + script_len + 4;
            k = k + 1;
        };

        let (out_count, off3) = read_varint(raw_tx, off);
        assert!(out_count <= MAX_OUTPUTS, errors::invalid_raw_tx());
        (out_count, off3)
    }

    public(package) fun parse_outputs(raw_tx: &vector<u8>): vector<TxOutput> {
        let (out_count, mut off) = outputs_cursor(raw_tx);
        let mut outs = vector[];
        let mut i = 0;
        while (i < out_count) {
            let value = read_u64_le(raw_tx, off);
            off = off + 8;
            let (script_len, off2) = read_varint(raw_tx, off);
            off = off2;
            let script = slice(raw_tx, off, script_len);
            off = off + script_len;
            vector::push_back(&mut outs, TxOutput { value, script_pubkey: script });
            i = i + 1;
        };
        outs
    }

    public(package) fun parse_inputs(raw_tx: &vector<u8>): vector<TxInput> {
        let len = vector::length(raw_tx);
        assert!(len >= MIN_TX_BYTES && len <= MAX_TX_BYTES, errors::invalid_raw_tx());

        let mut off = 4; // version
        if (len >= off + 2 && *vector::borrow(raw_tx, off) == 0x00 && *vector::borrow(raw_tx, off + 1) == 0x01) {
            off = off + 2;
        };
        let (in_count, off1) = read_varint(raw_tx, off);
        off = off1;
        assert!(in_count <= MAX_INPUTS, errors::invalid_raw_tx());

        let mut ins = vector[];
        let mut k = 0;
        while (k < in_count) {
            ensure(raw_tx, off, 36);
            let prev_txid = slice(raw_tx, off, 32);
            let prev_vout = read_u32_le(raw_tx, off + 32);
            off = off + 36;
            let (script_len, off2) = read_varint(raw_tx, off);
            off = off2;
            ensure(raw_tx, off, script_len + 4);
            off = off + script_len + 4;
            vector::push_back(&mut ins, TxInput { prev_txid, prev_vout });
            k = k + 1;
        };
        ins
    }

    // ---------------------------------------------------------------------
    // Deposit-specific selectors (port of bitcoin.rs find_* helpers)
    // ---------------------------------------------------------------------

    /// Parse one scriptPubKey for the 73-byte v1 Sui deposit OP_RETURN. Accepts
    /// direct-push (0x6a 0x49 ‖ 73) and PUSHDATA1 (0x6a 0x4c 0x49 ‖ 73).
    /// Returns (ok, pool_tag, ephemeral, npk).
    public(package) fun parse_deposit_op_return(script: &vector<u8>): (bool, vector<u8>, vector<u8>, vector<u8>) {
        let n = vector::length(script);
        let payload = if (
            n == 2 + DEPOSIT_OP_RETURN_SIZE
                && *vector::borrow(script, 0) == OP_RETURN
                && *vector::borrow(script, 1) == 0x49
        ) {
            slice(script, 2, DEPOSIT_OP_RETURN_SIZE)
        } else if (
            n == 3 + DEPOSIT_OP_RETURN_SIZE
                && *vector::borrow(script, 0) == OP_RETURN
                && *vector::borrow(script, 1) == 0x4c
                && *vector::borrow(script, 2) == 0x49
        ) {
            slice(script, 3, DEPOSIT_OP_RETURN_SIZE)
        } else {
            return (false, vector[], vector[], vector[])
        };
        let header = *vector::borrow(&payload, 0);
        let ok_header = header == DEPOSIT_HEADER_SUI_MAINNET
            || header == DEPOSIT_HEADER_SUI_TESTNET4
            || header == DEPOSIT_HEADER_SUI_REGTEST;
        if (!ok_header) {
            return (false, vector[], vector[], vector[])
        };
        (true, slice(&payload, 1, 8), slice(&payload, 9, 32), slice(&payload, 41, 32))
    }

    /// First output carrying a valid 73-byte deposit OP_RETURN. (ok, pool_tag, ephemeral, npk).
    public(package) fun find_deposit_op_return(raw_tx: &vector<u8>): (bool, vector<u8>, vector<u8>, vector<u8>) {
        let outs = parse_outputs(raw_tx);
        let mut i = 0;
        let n = vector::length(&outs);
        while (i < n) {
            let o = vector::borrow(&outs, i);
            let (ok, tag, eph, npk) = parse_deposit_op_return(&o.script_pubkey);
            if (ok) { return (true, tag, eph, npk) };
            i = i + 1;
        };
        (false, vector[], vector[], vector[])
    }

    fun is_op_return_script(script: &vector<u8>): bool {
        vector::length(script) >= 1 && *vector::borrow(script, 0) == OP_RETURN
    }

    /// First non-OP_RETURN output with value > 0. (ok, output, vout). vout is the absolute
    /// output index (OP_RETURN outputs are counted), matching Solana enumerate semantics.
    public(package) fun find_deposit_output_with_vout(raw_tx: &vector<u8>): (bool, TxOutput, u32) {
        let outs = parse_outputs(raw_tx);
        let mut i = 0;
        let n = vector::length(&outs);
        while (i < n) {
            let o = *vector::borrow(&outs, i);
            if (!is_op_return_script(&o.script_pubkey) && o.value > 0) {
                return (true, o, (i as u32))
            };
            i = i + 1;
        };
        (false, TxOutput { value: 0, script_pubkey: vector[] }, 0)
    }

    /// First output whose scriptPubKey equals `script` and value > 0 (binds the credited
    /// output to the pool/Ika P2TR). (ok, output, vout).
    public(package) fun find_output_by_script(
        raw_tx: &vector<u8>,
        script: &vector<u8>,
    ): (bool, TxOutput, u32) {
        let outs = parse_outputs(raw_tx);
        let mut i = 0;
        let n = vector::length(&outs);
        while (i < n) {
            let o = *vector::borrow(&outs, i);
            if (&o.script_pubkey == script && o.value > 0) {
                return (true, o, (i as u32))
            };
            i = i + 1;
        };
        (false, TxOutput { value: 0, script_pubkey: vector[] }, 0)
    }

    public(package) fun sum_outputs(raw_tx: &vector<u8>): u64 {
        let outs = parse_outputs(raw_tx);
        let mut total = 0u64;
        let mut i = 0;
        let n = vector::length(&outs);
        while (i < n) {
            let o = vector::borrow(&outs, i);
            total = total + o.value;
            i = i + 1;
        };
        total
    }

    /// True iff some input spends exactly `(txid, vout)` — the hardened deposit→sweep
    /// linkage (binds the specific funding outpoint, not just "some input touches txid").
    public(package) fun has_input_with_prev_outpoint(
        raw_tx: &vector<u8>,
        txid: &vector<u8>,
        vout: u32,
    ): bool {
        let ins = parse_inputs(raw_tx);
        let mut i = 0;
        let n = vector::length(&ins);
        while (i < n) {
            let inp = vector::borrow(&ins, i);
            if (&inp.prev_txid == txid && inp.prev_vout == vout) { return true };
            i = i + 1;
        };
        false
    }

    // ---------------------------------------------------------------------
    // Test-only constructors / accessors
    // ---------------------------------------------------------------------

    #[test_only]
    public fun test_read_varint(data: vector<u8>, off: u64): (u64, u64) { read_varint(&data, off) }
}
