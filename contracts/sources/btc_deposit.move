/// Trustless BTC deposit completion (Move port of `complete_deposit.rs`).
///
/// Consumes an SPV-proven `VerifiedInclusion` (module 01) + the raw tx bytes, binds the
/// bytes to the proven txid, extracts the deposit OP_RETURN note_public_key and credited output
/// trustlessly, applies fees, computes `Poseidon(note_public_key, ZKBTC_TOKEN_ID, shielded)` on-chain,
/// inserts the commitment into the real Poseidon tree (module 03), and dedups on the
/// immutable deposit outpoint via a Table. There is NO way to mint a commitment without a
/// valid SPV inclusion proof — the forgeable `new_verified_deposit` stub is gone.
module utxopia::btc_deposit {
    use sui::object::{Self, UID};
    use sui::object_table::{Self, ObjectTable};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use sui::table::{Self, Table};
    use sui::poseidon;
    use std::bcs;
    use std::hash;
    use utxopia::btc_light_client::{Self, VerifiedInclusion};
    use utxopia::bitcoin;
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};

    const UTXO_UNSPENT: u8 = 0;
    const UTXO_RESERVED: u8 = 1;

    /// O(1) outpoint dedup, keyed by outpoint_key(deposit_txid, deposit_vout).
    public struct BtcDepositRegistry has key {
        id: UID,
        claimed: Table<vector<u8>, bool>,
        claimed_count: u64,
    }

    /// Pool-controlled BTC UTXO recorded for later sweeping / redemption.
    public struct UtxoRecord has key, store {
        id: UID,
        pool_id: address,
        txid: vector<u8>,
        vout: u32,
        amount_sats: u64,
        status: u8,
    }

    public struct UtxoSet has key {
        id: UID,
        utxos: ObjectTable<vector<u8>, UtxoRecord>,
    }

    public fun initialize_registry(ctx: &mut TxContext) {
        transfer::share_object(BtcDepositRegistry {
            id: object::new(ctx),
            claimed: table::new(ctx),
            claimed_count: 0,
        });
    }

    public fun initialize_utxo_set(ctx: &mut TxContext) {
        transfer::share_object(UtxoSet { id: object::new(ctx), utxos: object_table::new(ctx) });
    }

    /// Permissionless. Completes a deposit from an SPV-proven inclusion. Aborts on any
    /// inconsistency. `inclusion` must come from `btc_light_client::verify_tx_inclusion`
    /// in the same PTB (it has no abilities — it cannot be forged or persisted).
    ///
    /// - `sweep_raw_tx`: the SPV-included tx paying the pool (legacy-serialized).
    /// - `deposit_raw_tx`: the user tx carrying the OP_RETURN; ignored if `direct_to_pool`.
    /// - `direct_to_pool`: true ⇒ the sweep IS the deposit tx.
    public fun complete_deposit(
        pool: &mut Pool,
        registry: &mut BtcDepositRegistry,
        utxo_set: &mut UtxoSet,
        tree: &mut CommitmentTree,
        inclusion: VerifiedInclusion,
        sweep_raw_tx: vector<u8>,
        deposit_raw_tx: vector<u8>,
        direct_to_pool: bool,
        ctx: &mut TxContext,
    ) {
        pool::assert_not_paused(pool);
        // Pin canonical companions so a caller can't pass a fresh registry/tree to bypass
        // outpoint dedup or insert into a non-canonical tree under this pool's events.
        pool::assert_commitment_tree(pool, object::id(tree));
        pool::assert_btc_deposit_registry(pool, object::id(registry));
        pool::assert_utxo_set(pool, object::id(utxo_set));

        // Module 01 already enforced canonical chain + >= required confirmations.
        let (light_client_id, sweep_txid, _block_hash, _height, _merkle_root, _tx_index) =
            btc_light_client::consume_inclusion(inclusion);
        pool::assert_light_client(pool, light_client_id);

        // Bind the supplied raw tx to the SPV-proven txid (else a caller could prove
        // inclusion of one txid and feed unrelated bytes).
        assert!(bitcoin::double_sha256(&sweep_raw_tx) == sweep_txid, errors::invalid_btc_deposit());

        // Resolve the deposit tx + its txid.
        let (deposit_txid, deposit_tx_bytes) = if (direct_to_pool) {
            (sweep_txid, sweep_raw_tx)
        } else {
            (bitcoin::double_sha256(&deposit_raw_tx), deposit_raw_tx)
        };

        // OP_RETURN (pool_tag, ephemeral_pubkey, note_public_key) from the deposit tx.
        let (has_op_return, pool_tag, ephemeral_pubkey, note_public_key) = bitcoin::find_deposit_op_return(&deposit_tx_bytes);
        assert!(has_op_return, errors::invalid_stealth_op_return());
        assert!(pool_tag == expected_pool_tag(pool, tree), errors::invalid_stealth_op_return());

        // Credited output from the SWEEP tx (the SPV-proven tx paying the pool).
        let pool_script = pool::btc_pool_script(pool);
        let (found_out, credited, sweep_vout) = bitcoin::find_output_by_script(&sweep_raw_tx, &pool_script);
        assert!(found_out, errors::invalid_btc_deposit());
        let amount_sats = bitcoin::output_value(&credited);

        // Deposit outpoint (dedup key) + deposit→sweep linkage.
        let deposit_vout = if (direct_to_pool) {
            sweep_vout
        } else {
            let (found_d, _d_out, dvout) = bitcoin::find_deposit_output_with_vout(&deposit_tx_bytes);
            assert!(found_d, errors::invalid_btc_deposit());
            assert!(
                bitcoin::has_input_with_prev_outpoint(&sweep_raw_tx, &deposit_txid, dvout),
                errors::deposit_linkage_failed(),
            );
            dvout
        };

        // Bounds.
        assert!(amount_sats >= pool::min_deposit_sats(pool), errors::amount_too_small());
        assert!(amount_sats <= pool::max_deposit_sats(pool), errors::amount_too_large());

        // Fees computed entirely in u128 so an admin-configured service fee near u64::MAX
        // yields a clean fee_exceeds_amount rejection rather than an arithmetic-overflow abort.
        let protocol_fee = ((amount_sats as u128) * (pool::deposit_fee_bps(pool) as u128)) / 10_000;
        let total_fee = protocol_fee + (pool::service_fee_sats(pool) as u128);
        assert!((amount_sats as u128) > total_fee, errors::fee_exceeds_amount());
        let shielded_amount = amount_sats - (total_fee as u64);

        // Double-claim guard on the immutable deposit outpoint (NOT the malleable sweep txid).
        let claim_key = outpoint_key(&deposit_txid, deposit_vout);
        assert!(!table::contains(&registry.claimed, claim_key), errors::btc_deposit_already_claimed());
        table::add(&mut registry.claimed, claim_key, true);
        registry.claimed_count = registry.claimed_count + 1;

        // Commitment on-chain: Poseidon(note_public_key, token_id, shielded_amount).
        let note_public_key_field = commitment_tree::field_from_be_bytes(&note_public_key);
        let commitment_u256 = poseidon::poseidon_bn254(
            &vector[note_public_key_field, pool::btc_token_id(pool), (shielded_amount as u256)],
        );
        let commitment_be = commitment_tree::field_to_be_bytes(commitment_u256);

        let pool_id = pool::pool_id(pool);
        let leaf_index = commitment_tree::insert_commitment_bytes(tree, pool_id, commitment_be);

        // Record the pool UTXO (sweep outpoint).
        add_pool_utxo(utxo_set, pool_id, sweep_txid, sweep_vout, amount_sats, ctx);

        // Stealth announcement (deposit): btc_deposit_verified carries the plaintext amount,
        // ephemeral_pubkey, note_public_key, commitment, and leaf index the SDK scanner needs.
        events::btc_deposit_verified(
            pool_id,
            leaf_index,
            deposit_txid,
            deposit_vout,
            amount_sats,
            ephemeral_pubkey,
            note_public_key,
            commitment_be,
        );

        pool::record_deposit(pool, shielded_amount, amount_sats);
    }

    // --- read accessors ---

    public fun claimed_count(registry: &BtcDepositRegistry): u64 { registry.claimed_count }

    public fun is_claimed(registry: &BtcDepositRegistry, txid: vector<u8>, vout: u32): bool {
        table::contains(&registry.claimed, outpoint_key(&txid, vout))
    }

    public fun contains_utxo(utxo_set: &UtxoSet, txid: vector<u8>, vout: u32): bool {
        object_table::contains(&utxo_set.utxos, outpoint_key(&txid, vout))
    }

    #[test_only]
    public fun test_add_utxo(
        utxo_set: &mut UtxoSet,
        pool_id: address,
        txid: vector<u8>,
        vout: u32,
        amount_sats: u64,
        ctx: &mut TxContext,
    ) {
        add_pool_utxo(utxo_set, pool_id, txid, vout, amount_sats, ctx);
    }

    #[test_only]
    public fun test_utxo_status(utxo_set: &UtxoSet, txid: vector<u8>, vout: u32): u8 {
        let key = outpoint_key(&txid, vout);
        object_table::borrow(&utxo_set.utxos, key).status
    }

    public(package) fun reserve_utxo(
        utxo_set: &mut UtxoSet,
        pool_id: address,
        txid: vector<u8>,
        vout: u32,
    ): u64 {
        let key = outpoint_key(&txid, vout);
        assert!(object_table::contains(&utxo_set.utxos, key), errors::invalid_redemption());
        let record = object_table::borrow_mut(&mut utxo_set.utxos, key);
        assert!(record.pool_id == pool_id, errors::invalid_redemption());
        assert!(record.status == UTXO_UNSPENT, errors::invalid_redemption());
        record.status = UTXO_RESERVED;
        record.amount_sats
    }

    public(package) fun remove_reserved_utxo(
        utxo_set: &mut UtxoSet,
        pool_id: address,
        txid: vector<u8>,
        vout: u32,
    ): u64 {
        let key = outpoint_key(&txid, vout);
        assert!(object_table::contains(&utxo_set.utxos, key), errors::invalid_redemption());
        let record = object_table::remove(&mut utxo_set.utxos, key);
        let UtxoRecord {
            id,
            pool_id: record_pool_id,
            txid: _,
            vout: _,
            amount_sats,
            status,
        } = record;
        assert!(record_pool_id == pool_id, errors::invalid_redemption());
        assert!(status == UTXO_RESERVED, errors::invalid_redemption());
        object::delete(id);
        amount_sats
    }

    #[test_only]
    public fun test_remove_reserved_utxo(
        utxo_set: &mut UtxoSet,
        pool_id: address,
        txid: vector<u8>,
        vout: u32,
    ): u64 {
        remove_reserved_utxo(utxo_set, pool_id, txid, vout)
    }

    public(package) fun add_pool_utxo(
        utxo_set: &mut UtxoSet,
        pool_id: address,
        txid: vector<u8>,
        vout: u32,
        amount_sats: u64,
        ctx: &mut TxContext,
    ) {
        let key = outpoint_key(&txid, vout);
        assert!(!object_table::contains(&utxo_set.utxos, key), errors::utxo_exists());
        object_table::add(&mut utxo_set.utxos, key, UtxoRecord {
            id: object::new(ctx),
            pool_id,
            txid,
            vout,
            amount_sats,
            status: UTXO_UNSPENT,
        });
    }

    // --- helpers ---

    fun outpoint_key(txid: &vector<u8>, vout: u32): vector<u8> {
        let mut key = *txid;
        vector::push_back(&mut key, ((vout & 0xff) as u8));
        vector::push_back(&mut key, (((vout >> 8) & 0xff) as u8));
        vector::push_back(&mut key, (((vout >> 16) & 0xff) as u8));
        vector::push_back(&mut key, (((vout >> 24) & 0xff) as u8));
        key
    }

    fun expected_pool_tag(pool: &Pool, tree: &CommitmentTree): vector<u8> {
        let mut data = b"UTXOPIA_SUI";
        vector::append(&mut data, bcs::to_bytes(&pool::pool_id(pool)));
        vector::append(&mut data, bcs::to_bytes(&commitment_tree::id(tree)));
        bitcoin::slice(&hash::sha2_256(data), 0, 8)
    }
}
