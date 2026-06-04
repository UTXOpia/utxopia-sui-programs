module utxopia::errors {
    const E_POOL_PAUSED: u64 = 1;
    const E_INVALID_TREE_DEPTH: u64 = 2;
    const E_INVALID_COMMITMENT: u64 = 3;
    const E_NULLIFIER_SPENT: u64 = 4;
    const E_REDEMPTION_COMPLETED: u64 = 5;
    const E_INVALID_REDEMPTION: u64 = 6;
    const E_POLICY_REJECTED: u64 = 7;
    const E_INVALID_VERIFYING_KEY: u64 = 8;
    const E_VERIFYING_KEY_NOT_FOUND: u64 = 9;
    const E_INVALID_PROOF: u64 = 10;
    const E_TOO_MANY_PUBLIC_INPUTS: u64 = 11;
    const E_VERIFICATION_FAILED: u64 = 12;
    const E_INVALID_JOIN_SPLIT: u64 = 13;
    const E_INVALID_BTC_DEPOSIT: u64 = 14;
    const E_BTC_DEPOSIT_ALREADY_CLAIMED: u64 = 15;

    public fun pool_paused(): u64 { E_POOL_PAUSED }
    public fun invalid_tree_depth(): u64 { E_INVALID_TREE_DEPTH }
    public fun invalid_commitment(): u64 { E_INVALID_COMMITMENT }
    public fun nullifier_spent(): u64 { E_NULLIFIER_SPENT }
    public fun redemption_completed(): u64 { E_REDEMPTION_COMPLETED }
    public fun invalid_redemption(): u64 { E_INVALID_REDEMPTION }
    public fun policy_rejected(): u64 { E_POLICY_REJECTED }
    public fun invalid_verifying_key(): u64 { E_INVALID_VERIFYING_KEY }
    public fun verifying_key_not_found(): u64 { E_VERIFYING_KEY_NOT_FOUND }
    public fun invalid_proof(): u64 { E_INVALID_PROOF }
    public fun too_many_public_inputs(): u64 { E_TOO_MANY_PUBLIC_INPUTS }
    public fun verification_failed(): u64 { E_VERIFICATION_FAILED }
    public fun invalid_join_split(): u64 { E_INVALID_JOIN_SPLIT }
    public fun invalid_btc_deposit(): u64 { E_INVALID_BTC_DEPOSIT }
    public fun btc_deposit_already_claimed(): u64 { E_BTC_DEPOSIT_ALREADY_CLAIMED }
}
