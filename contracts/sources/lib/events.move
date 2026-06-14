module utxopia::events {
    use sui::event;
    public struct PoolCreated has copy, drop {
        pool_id: address,
        tree_depth: u64,
        version: u64,
    }
    public struct PoolPaused has copy, drop {
        pool_id: address,
        paused: bool,
    }
    public struct CommitmentInserted has copy, drop {
        pool_id: address,
        leaf_index: u64,
        commitment: vector<u8>,
    }
    public struct CommitmentTreeRotated has copy, drop {
        pool_id: address,
        old_tree_id: address,
        new_tree_id: address,
        new_tree_number: u32,
    }
    public struct BtcDepositVerified has copy, drop {
        pool_id: address,
        leaf_index: u64,
        deposit_txid: vector<u8>,
        deposit_vout: u32,
        amount_sats: u64,
        ephemeral_pubkey: vector<u8>,
        note_public_key: vector<u8>,
        commitment: vector<u8>,
    }
    public struct MerkleRootUpdated has copy, drop {
        pool_id: address,
        root_index: u64,
        root: vector<u8>,
    }
    public struct NullifierSpent has copy, drop {
        pool_id: address,
        nullifier: vector<u8>,
    }
    public struct RedemptionRequested has copy, drop {
        pool_id: address,
        redemption_id: u64,
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
    }
    public struct RedemptionCompleted has copy, drop {
        pool_id: address,
        redemption_id: u64,
        btc_txid: vector<u8>,
    }
    public struct IkaSigningApproved has copy, drop {
        pool_id: address,
        redemption_id: u64,
        sighash: vector<u8>,
    }
    public struct VerifyingKeyRegistered has copy, drop {
        registry_id: address,
        n_inputs: u8,
        n_outputs: u8,
        n_public: u8,
        vk_hash: vector<u8>,
    }
    public struct JoinSplitVerified has copy, drop {
        pool_id: address,
        n_inputs: u8,
        n_outputs: u8,
        vk_hash: vector<u8>,
    }
    public struct TokenRegistered has copy, drop {
        registry_id: address,
        token_id: u256,
        decimals: u8,
        fee_bps: u16,
    }
    public struct StealthAnnounced has copy, drop {
        pool_id: address,
        announcement_type: u8,
        ephemeral_pub: vector<u8>,
        amount: u64,
        commitment: vector<u8>,
        leaf_index: u64,
        token_id: u256,
    }
    public struct HeadersSubmitted has copy, drop {
        light_client_id: address,
        tip_hash: vector<u8>,
        tip_height: u64,
        total_chainwork: u256,
        reorg: bool,
    }
    public(package) fun pool_created(pool_id: address, tree_depth: u64, version: u64) {
        event::emit(PoolCreated { pool_id, tree_depth, version });
    }
    public(package) fun pool_paused(pool_id: address, paused: bool) {
        event::emit(PoolPaused { pool_id, paused });
    }
    public(package) fun commitment_inserted(pool_id: address, leaf_index: u64, commitment: vector<u8>) {
        event::emit(CommitmentInserted { pool_id, leaf_index, commitment });
    }
    public(package) fun btc_deposit_verified(
        pool_id: address,
        leaf_index: u64,
        deposit_txid: vector<u8>,
        deposit_vout: u32,
        amount_sats: u64,
        ephemeral_pubkey: vector<u8>,
        note_public_key: vector<u8>,
        commitment: vector<u8>,
    ) {
        event::emit(BtcDepositVerified {
            pool_id,
            leaf_index,
            deposit_txid,
            deposit_vout,
            amount_sats,
            ephemeral_pubkey,
            note_public_key,
            commitment,
        });
    }
    public(package) fun commitment_tree_rotated(
        pool_id: address,
        old_tree_id: address,
        new_tree_id: address,
        new_tree_number: u32,
    ) {
        event::emit(CommitmentTreeRotated { pool_id, old_tree_id, new_tree_id, new_tree_number });
    }
    public(package) fun merkle_root_updated(pool_id: address, root_index: u64, root: vector<u8>) {
        event::emit(MerkleRootUpdated { pool_id, root_index, root });
    }
    public(package) fun nullifier_spent(pool_id: address, nullifier: vector<u8>) {
        event::emit(NullifierSpent { pool_id, nullifier });
    }
    public(package) fun redemption_requested(
        pool_id: address,
        redemption_id: u64,
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
    ) {
        event::emit(RedemptionRequested {
            pool_id,
            redemption_id,
            btc_script,
            amount_sats,
            max_fee_sats,
        });
    }
    public(package) fun redemption_completed(pool_id: address, redemption_id: u64, btc_txid: vector<u8>) {
        event::emit(RedemptionCompleted { pool_id, redemption_id, btc_txid });
    }
    public(package) fun ika_signing_approved(pool_id: address, redemption_id: u64, sighash: vector<u8>) {
        event::emit(IkaSigningApproved { pool_id, redemption_id, sighash });
    }
    public(package) fun verifying_key_registered(
        registry_id: address,
        n_inputs: u8,
        n_outputs: u8,
        n_public: u8,
        vk_hash: vector<u8>,
    ) {
        event::emit(VerifyingKeyRegistered {
            registry_id,
            n_inputs,
            n_outputs,
            n_public,
            vk_hash,
        });
    }
    public(package) fun join_split_verified(
        pool_id: address,
        n_inputs: u8,
        n_outputs: u8,
        vk_hash: vector<u8>,
    ) {
        event::emit(JoinSplitVerified {
            pool_id,
            n_inputs,
            n_outputs,
            vk_hash,
        });
    }
    public(package) fun token_registered(
        registry_id: address,
        token_id: u256,
        decimals: u8,
        fee_bps: u16,
    ) {
        event::emit(TokenRegistered { registry_id, token_id, decimals, fee_bps });
    }
    public struct FeesClaimed has copy, drop {
        registry_id: address,
        token_id: u256,
        amount: u64,
        recipient: address,
    }
    public(package) fun fees_claimed(
        registry_id: address,
        token_id: u256,
        amount: u64,
        recipient: address,
    ) {
        event::emit(FeesClaimed { registry_id, token_id, amount, recipient });
    }
    public(package) fun stealth_announced(
        pool_id: address,
        announcement_type: u8,
        ephemeral_pub: vector<u8>,
        amount: u64,
        commitment: vector<u8>,
        leaf_index: u64,
        token_id: u256,
    ) {
        event::emit(StealthAnnounced {
            pool_id,
            announcement_type,
            ephemeral_pub,
            amount,
            commitment,
            leaf_index,
            token_id,
        });
    }
    public(package) fun headers_submitted(
        light_client_id: address,
        tip_hash: vector<u8>,
        tip_height: u64,
        total_chainwork: u256,
        reorg: bool,
    ) {
        event::emit(HeadersSubmitted {
            light_client_id,
            tip_hash,
            tip_height,
            total_chainwork,
            reorg,
        });
    }
}
