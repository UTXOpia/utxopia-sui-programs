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
    }
}
