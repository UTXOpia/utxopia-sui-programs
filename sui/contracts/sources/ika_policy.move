module utxopia::ika_policy {
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};
    use utxopia::redemption::{Self, RedemptionQueue};

    public fun approve_signing(
        pool: &Pool,
        queue: &RedemptionQueue,
        redemption_id: u64,
        sighash: vector<u8>,
    ) {
        pool::assert_not_paused(pool);
        assert!(redemption::is_pending(queue, redemption_id), errors::policy_rejected());
        assert!(vector::length(&sighash) == 32, errors::policy_rejected());

        events::ika_signing_approved(pool::pool_id(pool), redemption_id, sighash);
    }
}
