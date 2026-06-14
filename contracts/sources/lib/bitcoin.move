module utxopia::bitcoin {
    use std::hash;
    use utxopia::errors;
    const OP_RETURN: u8 = 0x6a;
    const DEPOSIT_OP_RETURN_SIZE: u64 = 73;
    const DEPOSIT_HEADER_SUI_MAINNET: u8 = 0x60;
    const DEPOSIT_HEADER_SUI_TESTNET4: u8 = 0x62;
    const DEPOSIT_HEADER_SUI_REGTEST: u8 = 0x63;
    const MAX_INPUTS: u64 = 8_000;
    const MAX_OUTPUTS: u64 = 8_000;
    const MAX_TX_BYTES: u64 = 400_000;
    const MIN_TX_BYTES: u64 = 10;
    public struct TxOutput has copy, drop { value: u64, script_pubkey: vector<u8> }
    public struct TxInput has copy, drop { prev_txid: vector<u8>, prev_vout: u32 }
    public(package) fun output_value(o: &TxOutput): u64 { o.value }
    fun ensure(data: &vector<u8>, off: u64, need: u64) {
        assert!(off + need <= vector::length(data), errors::tx_truncated());
    }
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
    fun outputs_cursor(raw_tx: &vector<u8>): (u64, u64) {
        let len = vector::length(raw_tx);
        assert!(len >= MIN_TX_BYTES && len <= MAX_TX_BYTES, errors::invalid_raw_tx());
        let mut off = 4;
        if (len >= off + 2 && *vector::borrow(raw_tx, off) == 0x00 && *vector::borrow(raw_tx, off + 1) == 0x01) {
            off = off + 2;
        };
        let (in_count, off1) = read_varint(raw_tx, off);
        off = off1;
        assert!(in_count <= MAX_INPUTS, errors::invalid_raw_tx());
        let mut k = 0;
        while (k < in_count) {
            ensure(raw_tx, off, 36);
            off = off + 36;
            let (script_len, off2) = read_varint(raw_tx, off);
            off = off2;
            ensure(raw_tx, off, script_len + 4);
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
        let mut off = 4;
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
    public(package) fun find_deposit_op_return(raw_tx: &vector<u8>): (bool, vector<u8>, vector<u8>, vector<u8>) {
        let outs = parse_outputs(raw_tx);
        let mut i = 0;
        let n = vector::length(&outs);
        while (i < n) {
            let o = vector::borrow(&outs, i);
            let (ok, pool_tag, ephemeral_pubkey, note_public_key) = parse_deposit_op_return(&o.script_pubkey);
            if (ok) { return (true, pool_tag, ephemeral_pubkey, note_public_key) };
            i = i + 1;
        };
        (false, vector[], vector[], vector[])
    }
    fun is_op_return_script(script: &vector<u8>): bool {
        vector::length(script) >= 1 && *vector::borrow(script, 0) == OP_RETURN
    }
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
    public(package) fun input_count(raw_tx: &vector<u8>): u64 {
        vector::length(&parse_inputs(raw_tx))
    }
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
    #[test_only]
    public fun test_read_varint(data: vector<u8>, off: u64): (u64, u64) { read_varint(&data, off) }
}
