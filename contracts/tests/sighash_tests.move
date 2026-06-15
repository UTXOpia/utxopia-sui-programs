#[test_only]
module utxopia::sighash_tests {
    use utxopia::sighash;
    use std::hash;

    fun repeat(b: u8, n: u64): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    fun hex32(s: vector<u8>): vector<u8> {
        // s is 64 ascii hex chars
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 32) {
            let hi = nibble(*vector::borrow(&s, i * 2));
            let lo = nibble(*vector::borrow(&s, i * 2 + 1));
            vector::push_back(&mut out, (hi << 4) | lo);
            i = i + 1;
        };
        out
    }

    fun nibble(c: u8): u8 {
        if (c >= 0x30 && c <= 0x39) { c - 0x30 }
        else if (c >= 0x61 && c <= 0x66) { c - 0x61 + 10 }
        else { c - 0x41 + 10 }
    }

    // taproot scriptPubKey 0x5120 || 32-byte x-only key
    fun spk(fill: u8): vector<u8> {
        let mut v = vector[0x51u8, 0x20u8];
        vector::append(&mut v, repeat(fill, 32));
        v
    }

    // Ground-truth from the Solana program's sighash.rs test
    // (`matches_backend_and_rustbitcoin`): a 2-input, 2-output redemption tx.
    #[test]
    fun matches_solana_and_rustbitcoin_vectors() {
        // tag-hash sanity: SHA256("TapSighash") is the well-known BIP-341 tag.
        assert!(
            hash::sha2_256(b"TapSighash")
                == hex32(b"f40a48df4b2a70c8b4924bf2654661ed3d95fd66a313eb87237597c628e4a031"),
            100,
        );

        let pool = spk(0xAA);
        let dest = spk(0xBB);
        let in_txids = vector[repeat(0x11, 32), repeat(0x22, 32)];
        let in_vouts = vector[0u32, 1u32];
        let in_amounts = vector[100_000u64, 50_000u64];
        let in_seqs = vector[0xFFFF_FFFDu32, 0xFFFF_FFFDu32];
        let in_spks = vector[pool, pool];
        let out_amounts = vector[120_000u64, 29_000u64];
        let out_spks = vector[dest, pool];

        let sh0 = sighash::taproot_keyspend_sighash(
            2, 0, &in_txids, &in_vouts, &in_amounts, &in_seqs, &in_spks,
            &out_amounts, &out_spks, 0,
        );
        assert!(
            sh0 == hex32(b"741f7b5822be9747bf87f6289165307f8d2aa0f79ede2d76a6e7da9973248b6e"),
            0,
        );

        let sh1 = sighash::taproot_keyspend_sighash(
            2, 0, &in_txids, &in_vouts, &in_amounts, &in_seqs, &in_spks,
            &out_amounts, &out_spks, 1,
        );
        assert!(
            sh1 == hex32(b"e78496e38227bb132f348b9f07498b19832877d8441688b955bd78859036a5bd"),
            1,
        );
    }
}
