module utxopia::ika_policy {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};
    use utxopia::redemption::{Self, RedemptionQueue, RedemptionCap};
    use utxopia::btc_deposit::{Self, UtxoSet};
    use utxopia::sighash;
    const MAX_REDEMPTION_AMOUNT_SATS: u64 = 100_000_000;
    const MAX_MINER_FEE_SATS: u64 = 50_000;
    const SIGNING_APPROVAL_EXPIRY_EPOCHS: u64 = 1;
    const SIGHASH_LEN: u64 = 32;
    // Redemption-tx determinism contract (must match the off-chain tx builder):
    // nVersion=2, nLockTime=0, per-input nSequence=0xFFFF_FFFD, inputs ordered by
    // amount DESC then txid ASC then vout ASC, all spending the pool taproot
    // scriptPubKey, output[0]=recipient, output[1]=change-to-pool iff change>DUST.
    const BTC_TX_VERSION: u32 = 2;
    const BTC_TX_LOCKTIME: u32 = 0;
    const BTC_INPUT_SEQUENCE: u32 = 0xFFFF_FFFD;
    const BTC_DUST_THRESHOLD_SATS: u64 = 330;
    public struct SigningApproval has key, store {
        id: UID,
        pool_id: address,
        redemption_id: u64,
        input_index: u32,
        btc_script: vector<u8>,
        amount_sats: u64,
        sighash: vector<u8>,
        dwallet_cap_id: address,
        epoch_created: u64,
        used: bool,
    }
    public fun check_redemption_signing(pool: &Pool, amount_sats: u64, miner_fee_sats: u64) {
        pool::assert_not_paused(pool);
        assert!(amount_sats <= MAX_REDEMPTION_AMOUNT_SATS, errors::policy_rejected());
        assert!(miner_fee_sats <= MAX_MINER_FEE_SATS, errors::policy_rejected());
    }
    /// Authorize the Ika dWallet to sign one input of a redemption tx.
    ///
    /// The caller-supplied `sighash` is NOT trusted: the policy reconstructs the
    /// redemption tx (inputs = the request's reserved UTXOs, output[0] = recipient
    /// `btc_script`/`amount_sats`, output[1] = change back to the pool script) and
    /// recomputes the BIP-341 key-spend sighash for `input_index`, then asserts it
    /// equals `sighash`. This binds the signed message to validated on-chain state,
    /// closing the signing-oracle hole where a `RedemptionCap` holder could have the
    /// dWallet sign an arbitrary BTC transaction draining custody.
    public fun approve_signing(
        cap: &RedemptionCap,
        pool: &Pool,
        queue: &RedemptionQueue,
        utxo_set: &UtxoSet,
        dwallet_cap_id: address,
        redemption_id: u64,
        input_index: u32,
        estimated_miner_fee_sats: u64,
        sighash: vector<u8>,
        ctx: &mut TxContext,
    ) {
        redemption::assert_cap_for_queue(cap, queue);
        pool::assert_utxo_set(pool, object::id(utxo_set));
        assert!(vector::length(&sighash) == SIGHASH_LEN, errors::policy_rejected());
        assert!(redemption::is_pending(queue, redemption_id), errors::policy_rejected());
        // Only requests that have passed `mark_processing` carry a reserved input set.
        assert!(redemption::request_is_processing(queue, redemption_id), errors::policy_rejected());
        let pool_id = pool::pool_id(pool);
        assert!(redemption::request_pool_id(queue, redemption_id) == pool_id, errors::policy_rejected());
        let amount_sats = redemption::request_amount(queue, redemption_id);
        assert!(estimated_miner_fee_sats <= redemption::request_max_fee(queue, redemption_id), errors::policy_rejected());
        check_redemption_signing(pool, amount_sats, estimated_miner_fee_sats);

        // Reconstruct the redemption tx from validated state and bind the sighash.
        let total_input_sats = redemption::request_total_input_sats(queue, redemption_id);
        let mut txids = redemption::request_selected_txids(queue, redemption_id);
        let mut vouts = redemption::request_selected_vouts(queue, redemption_id);
        let n = vector::length(&txids);
        assert!(n > 0, errors::policy_rejected());
        assert!((input_index as u64) < n, errors::policy_rejected());

        // Per-input amounts come from the reserved pool UTXOs, not the caller.
        let mut amounts = vector[];
        let mut sum_inputs = 0u64;
        let mut i = 0u64;
        while (i < n) {
            let a = btc_deposit::reserved_utxo_amount(
                utxo_set, pool_id, vector::borrow(&txids, i), *vector::borrow(&vouts, i),
            );
            sum_inputs = sum_inputs + a;
            vector::push_back(&mut amounts, a);
            i = i + 1;
        };
        assert!(sum_inputs == total_input_sats, errors::policy_rejected());

        // Canonical input ordering: amount DESC, then txid ASC, then vout ASC.
        canonical_sort(&mut txids, &mut vouts, &mut amounts);

        let pool_script = pool::btc_pool_script(pool);
        let mut in_seqs = vector[];
        let mut in_spks = vector[];
        let mut j = 0u64;
        while (j < n) {
            vector::push_back(&mut in_seqs, BTC_INPUT_SEQUENCE);
            vector::push_back(&mut in_spks, pool_script);
            j = j + 1;
        };

        // Outputs: recipient gets exactly amount_sats (matching complete_redemption's
        // `output_value == amount_sats` check); change > dust returns to the pool.
        assert!(total_input_sats >= amount_sats + estimated_miner_fee_sats, errors::policy_rejected());
        let change = total_input_sats - amount_sats - estimated_miner_fee_sats;
        let btc_script = redemption::request_btc_script(queue, redemption_id);
        let mut out_amounts = vector[amount_sats];
        let mut out_spks = vector[btc_script];
        if (change > BTC_DUST_THRESHOLD_SATS) {
            vector::push_back(&mut out_amounts, change);
            vector::push_back(&mut out_spks, pool_script);
        };

        let computed = sighash::taproot_keyspend_sighash(
            BTC_TX_VERSION,
            BTC_TX_LOCKTIME,
            &txids,
            &vouts,
            &amounts,
            &in_seqs,
            &in_spks,
            &out_amounts,
            &out_spks,
            input_index,
        );
        assert!(computed == sighash, errors::policy_rejected());

        events::ika_signing_approved(pool_id, redemption_id, sighash);
        transfer::share_object(SigningApproval {
            id: object::new(ctx),
            pool_id,
            redemption_id,
            input_index,
            btc_script: redemption::request_btc_script(queue, redemption_id),
            amount_sats,
            sighash,
            dwallet_cap_id,
            epoch_created: tx_context::epoch(ctx),
            used: false,
        });
    }
    public fun consume_approval(
        cap: &RedemptionCap,
        pool: &Pool,
        queue: &RedemptionQueue,
        approval: &mut SigningApproval,
        ctx: &TxContext,
    ) {
        redemption::assert_cap_for_queue(cap, queue);
        // A pause must freeze the signing pipeline: an approval minted before the pause
        // cannot be consumed (and thus signed by Ika) while the pool is paused.
        pool::assert_not_paused(pool);
        assert!(!approval.used, errors::approval_used());
        assert!(approval.pool_id == pool::pool_id(pool), errors::policy_rejected());
        assert!(redemption::is_pending(queue, approval.redemption_id), errors::policy_rejected());
        assert!(
            tx_context::epoch(ctx) <= approval.epoch_created + SIGNING_APPROVAL_EXPIRY_EPOCHS,
            errors::approval_expired(),
        );
        approval.used = true;
    }

    // Canonical input ordering shared with the off-chain tx builder: amount
    // DESCENDING, then txid ASCENDING, then vout ASCENDING. Selection sort over
    // parallel vectors (n <= MAX_SELECTED_UTXOS = 16).
    fun canonical_sort(
        txids: &mut vector<vector<u8>>,
        vouts: &mut vector<u32>,
        amounts: &mut vector<u64>,
    ) {
        let n = vector::length(txids);
        let mut p = 0u64;
        while (p < n) {
            let mut best = p;
            let mut q = p + 1;
            while (q < n) {
                if (input_before(
                    *vector::borrow(amounts, q), vector::borrow(txids, q), *vector::borrow(vouts, q),
                    *vector::borrow(amounts, best), vector::borrow(txids, best), *vector::borrow(vouts, best),
                )) {
                    best = q;
                };
                q = q + 1;
            };
            if (best != p) {
                vector::swap(txids, p, best);
                vector::swap(vouts, p, best);
                vector::swap(amounts, p, best);
            };
            p = p + 1;
        };
    }
    fun input_before(
        a_amt: u64, a_txid: &vector<u8>, a_vout: u32,
        b_amt: u64, b_txid: &vector<u8>, b_vout: u32,
    ): bool {
        if (a_amt != b_amt) { return a_amt > b_amt };
        if (a_txid != b_txid) { return txid_lt(a_txid, b_txid) };
        a_vout < b_vout
    }
    fun txid_lt(a: &vector<u8>, b: &vector<u8>): bool {
        let la = vector::length(a);
        let lb = vector::length(b);
        let m = if (la < lb) { la } else { lb };
        let mut i = 0u64;
        while (i < m) {
            let x = *vector::borrow(a, i);
            let y = *vector::borrow(b, i);
            if (x != y) { return x < y };
            i = i + 1;
        };
        la < lb
    }
    public fun approval_sighash(a: &SigningApproval): vector<u8> { a.sighash }
    public fun approval_redemption_id(a: &SigningApproval): u64 { a.redemption_id }
    public fun approval_input_index(a: &SigningApproval): u32 { a.input_index }
    public fun approval_used(a: &SigningApproval): bool { a.used }
    public fun approval_btc_script(a: &SigningApproval): vector<u8> { a.btc_script }
    public fun approval_amount_sats(a: &SigningApproval): u64 { a.amount_sats }
    public fun approval_dwallet_cap_id(a: &SigningApproval): address { a.dwallet_cap_id }
}
