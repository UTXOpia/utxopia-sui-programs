/// Redemption signing policy gate (Move port of `policy.rs` + `approve_redemption_signing.rs`).
///
/// Replaces the rubber-stamp `approve_signing` with a real, fund-safe gate: it enforces the
/// amount/fee caps, binds the approved sighash to a specific still-pending redemption and
/// its pinned destination `btc_script`, and records a single-use `SigningApproval` the
/// off-chain Ika signer must match (and consume in the same PTB) before producing a
/// Taproot signature.
///
/// Structural divergence from Solana (documented): Sui's Ika integration is a PTB composed
/// off-chain, so we cannot make the dWallet technically incapable of signing an unapproved
/// message the way Solana's `__ika_cpi_authority` PDA does. The authoritative safety net is
/// the completion-time SPV check in `redemption::complete_redemption` (funds cannot finalize
/// for an off-policy tx); this approval object reduces the off-chain blast radius.
module utxopia::ika_policy {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};
    use utxopia::redemption::{Self, RedemptionQueue, RedemptionCap};

    // Policy constants — MUST equal Solana policy.rs.
    const MAX_REDEMPTION_AMOUNT_SATS: u64 = 100_000_000; // 1 BTC
    const MAX_MINER_FEE_SATS: u64 = 50_000;
    const SIGNING_APPROVAL_EXPIRY_EPOCHS: u64 = 1;
    const SIGHASH_LEN: u64 = 32;

    /// Single-use, policy-checked authorization to Taproot-sign exactly one sighash for
    /// exactly one redemption. Shared so the off-chain signer can read it by id; only
    /// `consume_approval` (gated by RedemptionCap) can flip `used`.
    public struct SigningApproval has key, store {
        id: UID,
        pool_id: address,
        redemption_id: u64,
        btc_script: vector<u8>,
        amount_sats: u64,
        sighash: vector<u8>,
        dwallet_cap_id: address,
        epoch_created: u64,
        used: bool,
    }

    /// Pure predicate port of policy.rs::check_redemption_signing.
    public fun check_redemption_signing(pool: &Pool, amount_sats: u64, miner_fee_sats: u64) {
        pool::assert_not_paused(pool);
        assert!(amount_sats <= MAX_REDEMPTION_AMOUNT_SATS, errors::policy_rejected());
        assert!(miner_fee_sats <= MAX_MINER_FEE_SATS, errors::policy_rejected());
    }

    /// Create a single-use, policy-bound SigningApproval for one redemption.
    public fun approve_signing(
        cap: &RedemptionCap,
        pool: &Pool,
        queue: &RedemptionQueue,
        dwallet_cap_id: address,
        redemption_id: u64,
        estimated_miner_fee_sats: u64,
        sighash: vector<u8>,
        ctx: &mut TxContext,
    ) {
        redemption::assert_cap_for_queue(cap, queue);
        assert!(vector::length(&sighash) == SIGHASH_LEN, errors::policy_rejected());
        assert!(redemption::is_pending(queue, redemption_id), errors::policy_rejected());

        let amount_sats = redemption::request_amount(queue, redemption_id);
        let pool_id = pool::pool_id(pool);
        assert!(redemption::request_pool_id(queue, redemption_id) == pool_id, errors::policy_rejected());
        // Fee must be within policy AND within the per-request cap the user committed to.
        assert!(estimated_miner_fee_sats <= redemption::request_max_fee(queue, redemption_id), errors::policy_rejected());
        check_redemption_signing(pool, amount_sats, estimated_miner_fee_sats);

        events::ika_signing_approved(pool_id, redemption_id, sighash);

        transfer::share_object(SigningApproval {
            id: object::new(ctx),
            pool_id,
            redemption_id,
            btc_script: redemption::request_btc_script(queue, redemption_id),
            amount_sats,
            sighash,
            dwallet_cap_id,
            epoch_created: tx_context::epoch(ctx),
            used: false,
        });
    }

    /// Single-use consume: flips `used` after re-checking the approval is fresh, bound to
    /// this pool, and the redemption is still pending. Composed in the SAME PTB as the Ika
    /// `requestSign` by the off-chain signer so the approval burns atomically with signing.
    public fun consume_approval(
        cap: &RedemptionCap,
        pool: &Pool,
        queue: &RedemptionQueue,
        approval: &mut SigningApproval,
        ctx: &TxContext,
    ) {
        redemption::assert_cap_for_queue(cap, queue);
        assert!(!approval.used, errors::approval_used());
        assert!(approval.pool_id == pool::pool_id(pool), errors::policy_rejected());
        assert!(redemption::is_pending(queue, approval.redemption_id), errors::policy_rejected());
        assert!(
            tx_context::epoch(ctx) <= approval.epoch_created + SIGNING_APPROVAL_EXPIRY_EPOCHS,
            errors::approval_expired(),
        );
        approval.used = true;
    }

    // --- read-only getters for the off-chain signer / indexer ---
    public fun approval_sighash(a: &SigningApproval): vector<u8> { a.sighash }
    public fun approval_redemption_id(a: &SigningApproval): u64 { a.redemption_id }
    public fun approval_used(a: &SigningApproval): bool { a.used }
    public fun approval_btc_script(a: &SigningApproval): vector<u8> { a.btc_script }
    public fun approval_amount_sats(a: &SigningApproval): u64 { a.amount_sats }
    public fun approval_dwallet_cap_id(a: &SigningApproval): address { a.dwallet_cap_id }
}
