module utxopia::sighash {
    /// BIP-341 Taproot key-spend sighash reconstruction.
    ///
    /// Ported byte-for-byte from the Solana program's
    /// `programs/utxopia/src/utils/sighash.rs` (`taproot_keyspend_preimage`)
    /// so the Sui `ika_policy::approve_signing` gate can re-derive the exact
    /// message the Ika dWallet signs and bind redemption approval to the
    /// redemption's reserved UTXOs + recipient script. This closes the
    /// "unvalidated sighash" signing-oracle hole: instead of trusting a
    /// caller-supplied sighash, the program reconstructs it.
    ///
    /// `sha2_256(preimage)` equals rust-bitcoin's BIP-341 key-spend sighash
    /// (SIGHASH_DEFAULT). The determinism contract with the off-chain tx
    /// builder is: nVersion=2, nLockTime=0, per-input nSequence=0xFFFF_FFFD,
    /// inputs ordered by amount DESC then txid ASC then vout ASC, all spending
    /// the pool taproot scriptPubKey, output[0]=recipient, output[1]=change to
    /// pool (present iff change > DUST).
    use std::hash;

    /// Fixed BIP-341 key-spend preimage length: 64 (tag||tag) + 175 (sigMsg).
    const PREIMAGE_LEN: u64 = 239;

    fun u32_le(v: u32): vector<u8> {
        vector[
            ((v & 0xff) as u8),
            (((v >> 8) & 0xff) as u8),
            (((v >> 16) & 0xff) as u8),
            (((v >> 24) & 0xff) as u8),
        ]
    }

    fun u64_le(v: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 8) {
            vector::push_back(&mut out, (((v >> ((8 * i) as u8)) & 0xff) as u8));
            i = i + 1;
        };
        out
    }

    /// Bitcoin compact-size (varint) encoding. Scripts here are < 0xFD bytes,
    /// but we handle the full range to match consensus serialization exactly.
    fun push_compact_size(buf: &mut vector<u8>, n: u64) {
        if (n < 0xFD) {
            vector::push_back(buf, (n as u8));
        } else if (n <= 0xFFFF) {
            vector::push_back(buf, 0xFD);
            vector::append(buf, u32_le((n as u32)));
            // u32_le pushed 4 bytes; compact-size 0xFD takes only 2. Trim.
            vector::pop_back(buf);
            vector::pop_back(buf);
        } else if (n <= 0xFFFF_FFFF) {
            vector::push_back(buf, 0xFE);
            vector::append(buf, u32_le((n as u32)));
        } else {
            vector::push_back(buf, 0xFF);
            vector::append(buf, u64_le(n));
        }
    }

    fun append_all(dst: &mut vector<u8>, src: &vector<u8>) {
        let mut i = 0u64;
        let n = vector::length(src);
        while (i < n) {
            vector::push_back(dst, *vector::borrow(src, i));
            i = i + 1;
        };
    }

    /// Build the 239-byte tagged TapSighash preimage for `input_index`.
    /// Inputs/outputs are passed as parallel vectors. `sha2_256` of the result
    /// is the BIP-341 key-spend sighash.
    public fun taproot_keyspend_preimage(
        version: u32,
        locktime: u32,
        in_txids: &vector<vector<u8>>,
        in_vouts: &vector<u32>,
        in_amounts: &vector<u64>,
        in_seqs: &vector<u32>,
        in_spks: &vector<vector<u8>>,
        out_amounts: &vector<u64>,
        out_spks: &vector<vector<u8>>,
        input_index: u32,
    ): vector<u8> {
        let n_in = vector::length(in_txids);
        assert!(vector::length(in_vouts) == n_in, 0);
        assert!(vector::length(in_amounts) == n_in, 0);
        assert!(vector::length(in_seqs) == n_in, 0);
        assert!(vector::length(in_spks) == n_in, 0);
        let n_out = vector::length(out_amounts);
        assert!(vector::length(out_spks) == n_out, 0);

        let mut prevouts_buf = vector[];
        let mut amounts_buf = vector[];
        let mut spk_buf = vector[];
        let mut seq_buf = vector[];
        let mut i = 0u64;
        while (i < n_in) {
            append_all(&mut prevouts_buf, vector::borrow(in_txids, i));
            vector::append(&mut prevouts_buf, u32_le(*vector::borrow(in_vouts, i)));
            vector::append(&mut amounts_buf, u64_le(*vector::borrow(in_amounts, i)));
            let spk = vector::borrow(in_spks, i);
            push_compact_size(&mut spk_buf, vector::length(spk));
            append_all(&mut spk_buf, spk);
            vector::append(&mut seq_buf, u32_le(*vector::borrow(in_seqs, i)));
            i = i + 1;
        };

        let mut out_buf = vector[];
        let mut j = 0u64;
        while (j < n_out) {
            vector::append(&mut out_buf, u64_le(*vector::borrow(out_amounts, j)));
            let spk = vector::borrow(out_spks, j);
            push_compact_size(&mut out_buf, vector::length(spk));
            append_all(&mut out_buf, spk);
            j = j + 1;
        };

        let sha_prevouts = hash::sha2_256(prevouts_buf);
        let sha_amounts = hash::sha2_256(amounts_buf);
        let sha_spks = hash::sha2_256(spk_buf);
        let sha_seqs = hash::sha2_256(seq_buf);
        let sha_outputs = hash::sha2_256(out_buf);
        let tag = hash::sha2_256(b"TapSighash");

        let mut p = vector[];
        // 64-byte tagged-hash prefix: SHA256("TapSighash") twice.
        append_all(&mut p, &tag);
        append_all(&mut p, &tag);
        // sigMsg (175 bytes for key-path, no annex):
        vector::push_back(&mut p, 0x00); // sighash epoch
        vector::push_back(&mut p, 0x00); // hash_type = SIGHASH_DEFAULT
        vector::append(&mut p, u32_le(version));
        vector::append(&mut p, u32_le(locktime));
        append_all(&mut p, &sha_prevouts);
        append_all(&mut p, &sha_amounts);
        append_all(&mut p, &sha_spks);
        append_all(&mut p, &sha_seqs);
        append_all(&mut p, &sha_outputs);
        vector::push_back(&mut p, 0x00); // spend_type: key-path, no annex
        vector::append(&mut p, u32_le(input_index));
        assert!(vector::length(&p) == PREIMAGE_LEN, 0);
        p
    }

    /// Final BIP-341 key-spend sighash = `sha2_256(preimage)`.
    public fun taproot_keyspend_sighash(
        version: u32,
        locktime: u32,
        in_txids: &vector<vector<u8>>,
        in_vouts: &vector<u32>,
        in_amounts: &vector<u64>,
        in_seqs: &vector<u32>,
        in_spks: &vector<vector<u8>>,
        out_amounts: &vector<u64>,
        out_spks: &vector<vector<u8>>,
        input_index: u32,
    ): vector<u8> {
        hash::sha2_256(
            taproot_keyspend_preimage(
                version,
                locktime,
                in_txids,
                in_vouts,
                in_amounts,
                in_seqs,
                in_spks,
                out_amounts,
                out_spks,
                input_index,
            ),
        )
    }
}
