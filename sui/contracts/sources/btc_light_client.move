module utxopia::btc_light_client {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use utxopia::errors;

    public struct VerifiedBtcDeposit has key {
        id: UID,
        deposit_txid: vector<u8>,
        deposit_vout: u32,
        amount_sats: u64,
        op_return_payload: vector<u8>,
        commitment: vector<u8>,
        verified_root: vector<u8>,
    }

    public(package) fun new_verified_deposit(
        deposit_txid: vector<u8>,
        deposit_vout: u32,
        amount_sats: u64,
        op_return_payload: vector<u8>,
        commitment: vector<u8>,
        verified_root: vector<u8>,
        ctx: &mut TxContext,
    ): VerifiedBtcDeposit {
        assert!(vector::length(&deposit_txid) == 32, errors::invalid_btc_deposit());
        assert!(amount_sats > 0, errors::invalid_btc_deposit());
        assert!(vector::length(&op_return_payload) == 64, errors::invalid_btc_deposit());
        assert!(vector::length(&commitment) == 32, errors::invalid_commitment());
        assert!(vector::length(&verified_root) == 32, errors::invalid_commitment());

        VerifiedBtcDeposit {
            id: object::new(ctx),
            deposit_txid,
            deposit_vout,
            amount_sats,
            op_return_payload,
            commitment,
            verified_root,
        }
    }

    public(package) fun consume_verified_deposit(
        verified: VerifiedBtcDeposit,
    ): (vector<u8>, u32, u64, vector<u8>, vector<u8>, vector<u8>) {
        let VerifiedBtcDeposit {
            id,
            deposit_txid,
            deposit_vout,
            amount_sats,
            op_return_payload,
            commitment,
            verified_root,
        } = verified;
        object::delete(id);
        (deposit_txid, deposit_vout, amount_sats, op_return_payload, commitment, verified_root)
    }
}
