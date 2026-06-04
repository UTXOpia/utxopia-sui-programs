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
    const E_STALE_MERKLE_ROOT: u64 = 16;
    const E_TREE_FULL: u64 = 17;
    const E_COMMITMENT_OUT_OF_FIELD: u64 = 18;
    const E_HEADER_PREV_MISMATCH: u64 = 19;
    const E_POW_NOT_MET: u64 = 20;
    const E_BAD_BITS: u64 = 21;
    const E_UNKNOWN_BLOCK: u64 = 22;
    const E_NOT_CANONICAL: u64 = 23;
    const E_INSUFFICIENT_CONF: u64 = 24;
    const E_BAD_MERKLE_PROOF: u64 = 25;
    const E_LC_PAUSED: u64 = 26;
    const E_BAD_HEADER_LEN: u64 = 27;
    const E_BATCH_TOO_LARGE: u64 = 28;
    const E_TX_TRUNCATED: u64 = 29;
    const E_INVALID_RAW_TX: u64 = 30;

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
    public fun stale_merkle_root(): u64 { E_STALE_MERKLE_ROOT }
    public fun tree_full(): u64 { E_TREE_FULL }
    public fun commitment_out_of_field(): u64 { E_COMMITMENT_OUT_OF_FIELD }
    public fun header_prev_mismatch(): u64 { E_HEADER_PREV_MISMATCH }
    public fun pow_not_met(): u64 { E_POW_NOT_MET }
    public fun bad_bits(): u64 { E_BAD_BITS }
    public fun unknown_block(): u64 { E_UNKNOWN_BLOCK }
    public fun not_canonical(): u64 { E_NOT_CANONICAL }
    public fun insufficient_conf(): u64 { E_INSUFFICIENT_CONF }
    public fun bad_merkle_proof(): u64 { E_BAD_MERKLE_PROOF }
    public fun lc_paused(): u64 { E_LC_PAUSED }
    public fun bad_header_len(): u64 { E_BAD_HEADER_LEN }
    public fun batch_too_large(): u64 { E_BATCH_TOO_LARGE }
    public fun tx_truncated(): u64 { E_TX_TRUNCATED }
    public fun invalid_raw_tx(): u64 { E_INVALID_RAW_TX }
}
