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
    use utxopia::pool::{Self, Pool, AuditorCap};
    const UTXO_UNSPENT: u8 = 0;
    const UTXO_RESERVED: u8 = 1;
    public struct BtcDepositRegistry has key {
        id: UID,
        claimed: Table<vector<u8>, bool>,
        claimed_count: u64,
    }
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
    public fun complete_deposit(
        pool: &mut Pool,
        registry: &mut BtcDepositRegistry,
        utxo_set: &mut UtxoSet,
        tree: &mut CommitmentTree,
        inclusion: VerifiedInclusion,
        sweep_raw_tx: vector<u8>,
        deposit_raw_tx: vector<u8>,
        direct_to_pool: bool,
        auditor_ciphertext: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(!pool::is_permissioned(pool), errors::not_permissioned());
        complete_deposit_inner(pool, registry, utxo_set, tree, inclusion, sweep_raw_tx, deposit_raw_tx, direct_to_pool, auditor_ciphertext, ctx);
    }
    public fun complete_deposit_permissioned(
        auditor_cap: &AuditorCap,
        pool: &mut Pool,
        registry: &mut BtcDepositRegistry,
        utxo_set: &mut UtxoSet,
        tree: &mut CommitmentTree,
        inclusion: VerifiedInclusion,
        sweep_raw_tx: vector<u8>,
        deposit_raw_tx: vector<u8>,
        direct_to_pool: bool,
        auditor_ciphertext: vector<u8>,
        ctx: &mut TxContext,
    ) {
        pool::assert_auditor(auditor_cap, pool);
        assert!(!pool::auditor_is_frozen(pool), errors::auditor_frozen());
        complete_deposit_inner(pool, registry, utxo_set, tree, inclusion, sweep_raw_tx, deposit_raw_tx, direct_to_pool, auditor_ciphertext, ctx);
    }
    fun complete_deposit_inner(
        pool: &mut Pool,
        registry: &mut BtcDepositRegistry,
        utxo_set: &mut UtxoSet,
        tree: &mut CommitmentTree,
        inclusion: VerifiedInclusion,
        sweep_raw_tx: vector<u8>,
        deposit_raw_tx: vector<u8>,
        direct_to_pool: bool,
        auditor_ciphertext: vector<u8>,
        ctx: &mut TxContext,
    ) {
        pool::assert_not_paused(pool);
        pool::assert_commitment_tree(pool, object::id(tree));
        pool::assert_btc_deposit_registry(pool, object::id(registry));
        pool::assert_utxo_set(pool, object::id(utxo_set));
        let (light_client_id, sweep_txid, _block_hash, _height, _merkle_root, _tx_index) =
            btc_light_client::consume_inclusion(inclusion);
        pool::assert_light_client(pool, light_client_id);
        assert!(bitcoin::double_sha256(&sweep_raw_tx) == sweep_txid, errors::invalid_btc_deposit());
        let (deposit_txid, deposit_tx_bytes) = if (direct_to_pool) {
            (sweep_txid, sweep_raw_tx)
        } else {
            (bitcoin::double_sha256(&deposit_raw_tx), deposit_raw_tx)
        };
        let (has_op_return, pool_tag, ephemeral_pubkey, note_public_key) = bitcoin::find_deposit_op_return(&deposit_tx_bytes);
        assert!(has_op_return, errors::invalid_stealth_op_return());
        assert!(pool_tag == expected_pool_tag(pool, tree), errors::invalid_stealth_op_return());
        let note_public_key_field = commitment_tree::field_from_be_bytes(&note_public_key);
        let pool_script = pool::btc_pool_script(pool);
        let (found_out, credited, sweep_vout) = bitcoin::find_output_by_script(&sweep_raw_tx, &pool_script);
        assert!(found_out, errors::invalid_btc_deposit());
        // Resolve deposit_vout and amount_sats together.
        // For direct_to_pool the deposit IS the sweep output; for the non-direct
        // path we credit the deposit tx's own output value (not the first pool
        // output of the sweep, which may aggregate multiple deposits in a batch).
        let (deposit_vout, amount_sats) = if (direct_to_pool) {
            (sweep_vout, bitcoin::output_value(&credited))
        } else {
            let (found_d, d_out, dvout) = bitcoin::find_deposit_output_with_vout(&deposit_tx_bytes);
            assert!(found_d, errors::invalid_btc_deposit());
            assert!(
                bitcoin::has_input_with_prev_outpoint(&sweep_raw_tx, &deposit_txid, dvout),
                errors::deposit_linkage_failed(),
            );
            let deposit_amount = bitcoin::output_value(&d_out);
            // Conservative invariant: the sweep's matching pool output must pay
            // exactly the deposit's output value.  This prevents over-crediting
            // when the sweep consolidates many deposits and one pool output
            // carries the combined total (1-deposit-1-matching-output rule).
            assert!(bitcoin::output_value(&credited) == deposit_amount, errors::invalid_btc_deposit());
            (dvout, deposit_amount)
        };
        assert!(amount_sats >= pool::min_deposit_sats(pool), errors::amount_too_small());
        assert!(amount_sats <= pool::max_deposit_sats(pool), errors::amount_too_large());
        let protocol_fee = ((amount_sats as u128) * (pool::deposit_fee_bps(pool) as u128)) / 10_000;
        let total_fee = protocol_fee + (pool::service_fee_sats(pool) as u128);
        assert!((amount_sats as u128) > total_fee, errors::fee_exceeds_amount());
        let shielded_amount = amount_sats - (total_fee as u64);
        let claim_key = outpoint_key(&deposit_txid, deposit_vout);
        assert!(!table::contains(&registry.claimed, claim_key), errors::btc_deposit_already_claimed());
        table::add(&mut registry.claimed, claim_key, true);
        registry.claimed_count = registry.claimed_count + 1;
        let commitment_u256 = poseidon::poseidon_bn254(
            &vector[note_public_key_field, pool::btc_token_id(pool), (shielded_amount as u256)],
        );
        let commitment_be = commitment_tree::field_to_be_bytes(commitment_u256);
        let pool_id = pool::pool_id(pool);
        let leaf_index = commitment_tree::insert_commitment_bytes(tree, pool_id, commitment_be);
        add_pool_utxo(utxo_set, pool_id, sweep_txid, sweep_vout, amount_sats, ctx);
        events::btc_deposit_verified(
            pool_id,
            leaf_index,
            deposit_txid,
            deposit_vout,
            amount_sats,
            ephemeral_pubkey,
            note_public_key,
            commitment_be,
            auditor_ciphertext,
        );
        pool::record_deposit(pool, shielded_amount, amount_sats);
    }
    public fun claimed_count(registry: &BtcDepositRegistry): u64 { registry.claimed_count }
    public fun is_claimed(registry: &BtcDepositRegistry, txid: vector<u8>, vout: u32): bool {
        table::contains(&registry.claimed, outpoint_key(&txid, vout))
    }
    public fun contains_utxo(utxo_set: &UtxoSet, txid: vector<u8>, vout: u32): bool {
        object_table::contains(&utxo_set.utxos, outpoint_key(&txid, vout))
    }
    /// Amount (sats) of a reserved pool UTXO. Asserts the outpoint exists, is
    /// owned by `pool_id`, and is RESERVED (i.e. selected by `mark_processing`).
    /// Used by the signing-approval gate to reconstruct the redemption tx's
    /// per-input amounts when binding the dWallet sighash.
    public(package) fun reserved_utxo_amount(
        utxo_set: &UtxoSet,
        pool_id: address,
        txid: &vector<u8>,
        vout: u32,
    ): u64 {
        let key = outpoint_key(txid, vout);
        assert!(object_table::contains(&utxo_set.utxos, key), errors::invalid_redemption());
        let record = object_table::borrow(&utxo_set.utxos, key);
        assert!(record.pool_id == pool_id, errors::invalid_redemption());
        assert!(record.status == UTXO_RESERVED, errors::invalid_redemption());
        record.amount_sats
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
