#[test_only]
module utxopia::errors_tests {
    use utxopia::errors;

    #[test]
    fun exposes_stable_error_codes() {
        assert!(errors::pool_paused() == 1, 0);
        assert!(errors::invalid_tree_depth() == 2, 0);
        assert!(errors::invalid_commitment() == 3, 0);
        assert!(errors::nullifier_spent() == 4, 0);
        assert!(errors::redemption_completed() == 5, 0);
        assert!(errors::invalid_redemption() == 6, 0);
        assert!(errors::policy_rejected() == 7, 0);
        assert!(errors::invalid_verifying_key() == 8, 0);
        assert!(errors::verifying_key_not_found() == 9, 0);
        assert!(errors::invalid_proof() == 10, 0);
        assert!(errors::too_many_public_inputs() == 11, 0);
        assert!(errors::verification_failed() == 12, 0);
        assert!(errors::invalid_join_split() == 13, 0);
        assert!(errors::invalid_btc_deposit() == 14, 0);
        assert!(errors::btc_deposit_already_claimed() == 15, 0);
        assert!(errors::stale_merkle_root() == 16, 0);
        assert!(errors::tree_full() == 17, 0);
        assert!(errors::commitment_out_of_field() == 18, 0);
        assert!(errors::header_prev_mismatch() == 19, 0);
        assert!(errors::pow_not_met() == 20, 0);
        assert!(errors::bad_bits() == 21, 0);
        assert!(errors::unknown_block() == 22, 0);
        assert!(errors::not_canonical() == 23, 0);
        assert!(errors::insufficient_conf() == 24, 0);
        assert!(errors::bad_merkle_proof() == 25, 0);
        assert!(errors::lc_paused() == 26, 0);
        assert!(errors::bad_header_len() == 27, 0);
        assert!(errors::batch_too_large() == 28, 0);
        assert!(errors::tx_truncated() == 29, 0);
        assert!(errors::invalid_raw_tx() == 30, 0);
        assert!(errors::amount_too_small() == 31, 0);
        assert!(errors::amount_too_large() == 32, 0);
        assert!(errors::fee_exceeds_amount() == 33, 0);
        assert!(errors::invalid_stealth_op_return() == 34, 0);
        assert!(errors::utxo_exists() == 35, 0);
        assert!(errors::deposit_linkage_failed() == 36, 0);
        assert!(errors::approval_used() == 37, 0);
        assert!(errors::approval_expired() == 38, 0);
        assert!(errors::wrong_cap() == 39, 0);
        assert!(errors::wrong_object() == 40, 0);
        assert!(errors::already_bound() == 41, 0);
        assert!(errors::no_pending_proposal() == 42, 0);
        assert!(errors::timelock_not_elapsed() == 43, 0);
    }
}
