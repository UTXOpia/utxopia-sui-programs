module utxopia::btc_deposit {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use utxopia::btc_light_client::{Self, VerifiedBtcDeposit};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};

    const TXID_LEN: u64 = 32;
    const OP_RETURN_PAYLOAD_LEN: u64 = 64;
    const FIELD_BYTES_LEN: u64 = 32;

    public struct BtcDepositRegistry has key {
        id: UID,
        claimed_outpoints: vector<vector<u8>>,
    }

    public fun initialize_registry(ctx: &mut TxContext) {
        let registry = BtcDepositRegistry {
            id: object::new(ctx),
            claimed_outpoints: vector[],
        };
        transfer::share_object(registry);
    }

    public fun complete_verified_deposit(
        pool: &Pool,
        tree: &mut CommitmentTree,
        registry: &mut BtcDepositRegistry,
        verified_deposit: VerifiedBtcDeposit,
    ) {
        let (
            deposit_txid,
            deposit_vout,
            amount_sats,
            op_return_payload,
            commitment,
            _verified_root, // root is now computed on-chain by the tree, not trusted from input
        ) = btc_light_client::consume_verified_deposit(verified_deposit);

        pool::assert_not_paused(pool);
        assert!(amount_sats > 0, errors::invalid_btc_deposit());
        assert!(vector::length(&deposit_txid) == TXID_LEN, errors::invalid_btc_deposit());
        assert!(vector::length(&op_return_payload) == OP_RETURN_PAYLOAD_LEN, errors::invalid_btc_deposit());
        assert!(vector::length(&commitment) == FIELD_BYTES_LEN, errors::invalid_commitment());

        let claim_key = outpoint_key(&deposit_txid, deposit_vout);
        assert!(!contains_claim(registry, &claim_key), errors::btc_deposit_already_claimed());
        vector::push_back(&mut registry.claimed_outpoints, claim_key);

        let pool_id = pool::pool_id(pool);
        let ephemeral_pubkey = copy_range(&op_return_payload, 0, 32);
        let npk = copy_range(&op_return_payload, 32, 64);

        // Emit the stealth announcement with the leaf index the commitment will occupy,
        // then insert into the real Poseidon tree (which emits commitment_inserted +
        // merkle_root_updated and computes the new root on-chain).
        let leaf_index = commitment_tree::next_index(tree);
        events::btc_deposit_verified(
            pool_id,
            leaf_index,
            deposit_txid,
            deposit_vout,
            amount_sats,
            ephemeral_pubkey,
            npk,
            commitment,
        );
        commitment_tree::insert_commitment_bytes(tree, pool_id, commitment);
    }

    public fun claimed_count(registry: &BtcDepositRegistry): u64 {
        vector::length(&registry.claimed_outpoints)
    }

    fun contains_claim(registry: &BtcDepositRegistry, key: &vector<u8>): bool {
        let mut i = 0;
        let len = vector::length(&registry.claimed_outpoints);
        while (i < len) {
            if (vector::borrow(&registry.claimed_outpoints, i) == key) {
                return true
            };
            i = i + 1;
        };
        false
    }

    fun outpoint_key(txid: &vector<u8>, vout: u32): vector<u8> {
        let mut key = *txid;
        vector::push_back(&mut key, ((vout & 0xff) as u8));
        vector::push_back(&mut key, (((vout >> 8) & 0xff) as u8));
        vector::push_back(&mut key, (((vout >> 16) & 0xff) as u8));
        vector::push_back(&mut key, (((vout >> 24) & 0xff) as u8));
        key
    }

    fun copy_range(bytes: &vector<u8>, start: u64, end: u64): vector<u8> {
        let mut out = vector[];
        let mut i = start;
        while (i < end) {
            vector::push_back(&mut out, *vector::borrow(bytes, i));
            i = i + 1;
        };
        out
    }
}
