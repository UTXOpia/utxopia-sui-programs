module utxopia::redemption {
    use std::hash;
    use sui::object::{Self, ID, UID};
    use sui::object_table::{Self, ObjectTable};
    use sui::poseidon;
    use sui::transfer;
    use sui::tx_context::TxContext;
    use utxopia::bitcoin;
    use utxopia::btc_deposit::{Self, UtxoSet};
    use utxopia::btc_light_client::{Self, VerifiedInclusion};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, Pool};
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    const MAX_PUBLIC_REDEMPTIONS: u8 = 3;
    const MAX_SELECTED_UTXOS: u64 = 16;
    const BOUND_PARAMS_REDEEM_FLAG: u8 = 2;
    const SUI_BOUND_CHAIN_ID: u64 = 103;
    const BN254_FR: u256 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    /// Authority over exactly one RedemptionQueue (bound by `queue_id`).
    public struct RedemptionCap has key {
        id: UID,
        queue_id: ID,
    }

    public struct RedemptionQueue has key {
        id: UID,
        requests: ObjectTable<u64, RedemptionRequest>,
    }

    public struct RedemptionRequest has key, store {
        id: UID,
        request_id: u64,
        pool_id: address,
        /// Raw destination scriptPubKey (NOT a hash / bech32). Pins the destination so
        /// completion can byte-compare it against the SPV-verified broadcast output.
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
        processing: bool,
        total_input_sats: u64,
        selected_txids: vector<vector<u8>>,
        selected_vouts: vector<u32>,
        completed: bool,
    }

    public fun initialize_queue(ctx: &mut TxContext) {
        let queue = RedemptionQueue {
            id: object::new(ctx),
            requests: object_table::new(ctx),
        };
        let cap = RedemptionCap { id: object::new(ctx), queue_id: object::id(&queue) };

        transfer::share_object(queue);
        transfer::transfer(cap, sui::tx_context::sender(ctx));
    }

    fun assert_cap(cap: &RedemptionCap, queue: &RedemptionQueue) {
        assert!(cap.queue_id == object::id(queue), errors::wrong_cap());
    }

    /// Lets sibling modules (ika_policy) verify a cap authorizes this queue.
    public(package) fun assert_cap_for_queue(cap: &RedemptionCap, queue: &RedemptionQueue) {
        assert_cap(cap, queue);
    }

    #[test_only]
    public fun test_request_redemption(
        pool: &mut Pool,
        queue: &mut RedemptionQueue,
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
        ctx: &mut TxContext,
    ) {
        pool::assert_not_paused(pool);
        enqueue_redemption_request(pool, queue, btc_script, amount_sats, max_fee_sats, ctx);
    }

    public fun redeem(
        pool: &mut Pool,
        tree: &mut CommitmentTree,
        nullifiers: &mut NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
        queue: &mut RedemptionQueue,
        n_inputs: u8,
        n_outputs: u8,
        n_public_outputs: u8,
        vk_hash: vector<u8>,
        public_inputs: vector<u8>,
        proof_points: vector<u8>,
        nullifiers_in: vector<vector<u8>>,
        commitments_out: vector<vector<u8>>,
        btc_scripts: vector<vector<u8>>,
        amounts_sats: vector<u64>,
        max_fees_sats: vector<u64>,
        stealth_data: vector<vector<u8>>,
        ctx: &mut TxContext,
    ) {
        pool::assert_not_paused(pool);
        pool::assert_commitment_tree(pool, object::id(tree));
        pool::assert_nullifier_registry(pool, object::id(nullifiers));
        pool::assert_vk_registry(pool, object::id(vk_registry));
        assert!(n_public_outputs > 0, errors::invalid_redemption());
        assert!(n_public_outputs <= MAX_PUBLIC_REDEMPTIONS, errors::invalid_redemption());
        assert!(n_outputs >= n_public_outputs, errors::invalid_join_split());
        assert!(nullifiers_in.length() == (n_inputs as u64), errors::invalid_join_split());
        assert!(commitments_out.length() == (n_outputs as u64), errors::invalid_join_split());
        assert!(btc_scripts.length() == (n_public_outputs as u64), errors::invalid_redemption());
        assert!(amounts_sats.length() == (n_public_outputs as u64), errors::invalid_redemption());
        assert!(max_fees_sats.length() == (n_public_outputs as u64), errors::invalid_redemption());
        let n_tree_outputs = n_outputs - n_public_outputs;
        assert!(stealth_data.length() == (n_tree_outputs as u64), errors::invalid_join_split());
        assert_bound_public_inputs(&public_inputs, n_inputs, n_outputs, &nullifiers_in, &commitments_out);
        let bound_params_hash = compute_redeem_bound_params_hash(&btc_scripts, &stealth_data);
        assert_public_input_at(&public_inputs, 1, &bound_params_hash);

        assert_public_redeem_commitments(pool, n_tree_outputs, n_public_outputs, &commitments_out, &amounts_sats);

        let proof_root = extract_public_input(&public_inputs, 0);
        assert!(commitment_tree::is_valid_root_bytes(tree, &proof_root), errors::stale_merkle_root());

        let verified = verifier::verify_join_split(
            vk_registry,
            n_inputs,
            n_outputs,
            vk_hash,
            public_inputs,
            proof_points,
        );
        assert!(verified, errors::verification_failed());

        let pool_id = pool::pool_id(pool);
        events::join_split_verified(pool_id, n_inputs, n_outputs, vk_hash);

        let mut i = 0u64;
        while (i < nullifiers_in.length()) {
            nullifier::record_spend(pool_id, nullifiers, nullifiers_in[i]);
            i = i + 1;
        };

        let mut j = 0;
        while (j < (n_tree_outputs as u64)) {
            commitment_tree::insert_commitment_bytes(tree, pool_id, commitments_out[j]);
            j = j + 1;
        };

        let mut total_redeemed = 0u128;
        let mut k = 0;
        while (k < (n_public_outputs as u64)) {
            let btc_script = *btc_scripts.borrow(k);
            let amount_sats = *amounts_sats.borrow(k);
            let max_fee_sats = *max_fees_sats.borrow(k);
            assert!(amount_sats > 0, errors::invalid_redemption());
            assert!(btc_script.length() > 0, errors::invalid_redemption());

            total_redeemed = total_redeemed + (amount_sats as u128);
            enqueue_redemption_request(pool, queue, btc_script, amount_sats, max_fee_sats, ctx);
            k = k + 1;
        };
        pool::record_redemption_request(pool, total_redeemed);
    }

    public fun mark_processing(
        cap: &RedemptionCap,
        pool: &Pool,
        utxo_set: &mut UtxoSet,
        queue: &mut RedemptionQueue,
        redemption_id: u64,
        selected_txids: vector<vector<u8>>,
        selected_vouts: vector<u32>,
        estimated_miner_fee_sats: u64,
    ) {
        assert_cap(cap, queue);
        pool::assert_not_paused(pool);
        pool::assert_utxo_set(pool, object::id(utxo_set));
        let pool_id = pool::pool_id(pool);
        let request = borrow_request_mut(queue, redemption_id);
        assert!(request.pool_id == pool_id, errors::invalid_redemption());
        assert!(!request.completed, errors::redemption_completed());
        assert!(!request.processing, errors::invalid_redemption());
        assert!(vector::length(&selected_txids) > 0, errors::invalid_redemption());
        assert!(vector::length(&selected_txids) <= MAX_SELECTED_UTXOS, errors::invalid_redemption());
        assert!(vector::length(&selected_txids) == vector::length(&selected_vouts), errors::invalid_redemption());
        assert!(estimated_miner_fee_sats <= request.max_fee_sats, errors::invalid_redemption());

        let mut total_input_sats = 0u64;
        let mut i = 0u64;
        while (i < vector::length(&selected_txids)) {
            let amount = btc_deposit::reserve_utxo(utxo_set, pool_id, selected_txids[i], selected_vouts[i]);
            total_input_sats = total_input_sats + amount;
            i = i + 1;
        };
        assert!(total_input_sats >= request.amount_sats + estimated_miner_fee_sats, errors::invalid_redemption());

        request.processing = true;
        request.total_input_sats = total_input_sats;
        request.selected_txids = selected_txids;
        request.selected_vouts = selected_vouts;
    }

    public fun complete_redemption(
        cap: &RedemptionCap,
        pool: &Pool,
        utxo_set: &mut UtxoSet,
        queue: &mut RedemptionQueue,
        redemption_id: u64,
        inclusion: VerifiedInclusion,
        raw_tx: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert_cap(cap, queue);
        pool::assert_utxo_set(pool, object::id(utxo_set));
        let pool_id = pool::pool_id(pool);
        let (btc_script, amount_sats, max_fee_sats, total_input_sats, selected_txids, selected_vouts) = {
            let request = borrow_request_mut(queue, redemption_id);
            assert!(!request.completed, errors::redemption_completed());
            assert!(request.processing, errors::invalid_redemption());
            assert!(request.pool_id == pool_id, errors::invalid_redemption());
            (
                request.btc_script,
                request.amount_sats,
                request.max_fee_sats,
                request.total_input_sats,
                request.selected_txids,
                request.selected_vouts,
            )
        };

        let (light_client_id, btc_txid, _block_hash, _height, _merkle_root, _tx_index) =
            btc_light_client::consume_inclusion(inclusion);
        pool::assert_light_client(pool, light_client_id);
        assert!(bitcoin::double_sha256(&raw_tx) == btc_txid, errors::invalid_redemption());

        let (found, output, _vout) = bitcoin::find_output_by_script(&raw_tx, &btc_script);
        assert!(found, errors::invalid_redemption());
        assert!(bitcoin::output_value(&output) == amount_sats, errors::invalid_redemption());

        let mut selected_total = 0u64;
        let mut i = 0u64;
        while (i < vector::length(&selected_txids)) {
            assert!(
                bitcoin::has_input_with_prev_outpoint(&raw_tx, &selected_txids[i], selected_vouts[i]),
                errors::invalid_redemption(),
            );
            selected_total = selected_total + btc_deposit::remove_reserved_utxo(
                utxo_set,
                pool_id,
                selected_txids[i],
                selected_vouts[i],
            );
            i = i + 1;
        };
        assert!(selected_total == total_input_sats, errors::invalid_redemption());

        let total_outputs = bitcoin::sum_outputs(&raw_tx);
        assert!(total_input_sats >= total_outputs, errors::invalid_redemption());
        let miner_fee = total_input_sats - total_outputs;
        assert!(miner_fee <= max_fee_sats, errors::invalid_redemption());

        let pool_script = pool::btc_pool_script(pool);
        let (has_change, change_output, change_vout) = bitcoin::find_output_by_script(&raw_tx, &pool_script);
        if (has_change) {
            btc_deposit::add_pool_utxo(
                utxo_set,
                pool_id,
                btc_txid,
                change_vout,
                bitcoin::output_value(&change_output),
                ctx,
            );
        };

        events::redemption_completed(pool_id, redemption_id, btc_txid);
        remove_request(queue, redemption_id, pool_id);
    }

    public(package) fun is_pending(queue: &RedemptionQueue, redemption_id: u64): bool {
        let request = borrow_request(queue, redemption_id);
        !request.completed
    }

    public(package) fun request_amount(queue: &RedemptionQueue, redemption_id: u64): u64 {
        borrow_request(queue, redemption_id).amount_sats
    }

    public(package) fun request_pool_id(queue: &RedemptionQueue, redemption_id: u64): address {
        borrow_request(queue, redemption_id).pool_id
    }

    public(package) fun request_max_fee(queue: &RedemptionQueue, redemption_id: u64): u64 {
        borrow_request(queue, redemption_id).max_fee_sats
    }

    public(package) fun request_btc_script(queue: &RedemptionQueue, redemption_id: u64): vector<u8> {
        borrow_request(queue, redemption_id).btc_script
    }

    fun borrow_request(queue: &RedemptionQueue, redemption_id: u64): &RedemptionRequest {
        assert!(object_table::contains(&queue.requests, redemption_id), errors::invalid_redemption());
        object_table::borrow(&queue.requests, redemption_id)
    }

    fun borrow_request_mut(queue: &mut RedemptionQueue, redemption_id: u64): &mut RedemptionRequest {
        assert!(object_table::contains(&queue.requests, redemption_id), errors::invalid_redemption());
        object_table::borrow_mut(&mut queue.requests, redemption_id)
    }

    fun remove_request(queue: &mut RedemptionQueue, redemption_id: u64, pool_id: address) {
        assert!(object_table::contains(&queue.requests, redemption_id), errors::invalid_redemption());
        let request = object_table::remove(&mut queue.requests, redemption_id);
        let RedemptionRequest {
            id,
            request_id,
            pool_id: request_pool_id,
            btc_script: _,
            amount_sats: _,
            max_fee_sats: _,
            processing: _,
            total_input_sats: _,
            selected_txids: _,
            selected_vouts: _,
            completed: _,
        } = request;
        assert!(request_id == redemption_id, errors::invalid_redemption());
        assert!(request_pool_id == pool_id, errors::invalid_redemption());
        object::delete(id);
    }

    fun enqueue_redemption_request(
        pool: &mut Pool,
        queue: &mut RedemptionQueue,
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
        ctx: &mut TxContext,
    ): u64 {
        assert!(amount_sats > 0, errors::invalid_redemption());
        assert!(vector::length(&btc_script) > 0, errors::invalid_redemption());

        let redemption_id = pool::allocate_redemption_id(pool);
        let pool_id = pool::pool_id(pool);
        object_table::add(&mut queue.requests, redemption_id, RedemptionRequest {
            id: object::new(ctx),
            request_id: redemption_id,
            pool_id,
            btc_script,
            amount_sats,
            max_fee_sats,
            processing: false,
            total_input_sats: 0,
            selected_txids: vector[],
            selected_vouts: vector[],
            completed: false,
        });

        let request = object_table::borrow(&queue.requests, redemption_id);
        events::redemption_requested(pool_id, redemption_id, request.btc_script, amount_sats, max_fee_sats);
        redemption_id
    }

    fun assert_bound_public_inputs(
        public_inputs: &vector<u8>,
        n_inputs: u8,
        n_outputs: u8,
        nullifiers_in: &vector<vector<u8>>,
        commitments_out: &vector<vector<u8>>,
    ) {
        let expected_len = ((2 + (n_inputs as u64) + (n_outputs as u64)) * 32);
        assert!(public_inputs.length() == expected_len, errors::invalid_join_split());

        let mut i = 0u64;
        while (i < (n_inputs as u64)) {
            assert_public_input_at(public_inputs, 2 + i, &nullifiers_in[i]);
            i = i + 1;
        };

        let mut j = 0;
        while (j < (n_outputs as u64)) {
            assert_public_input_at(public_inputs, 2 + (n_inputs as u64) + j, &commitments_out[j]);
            j = j + 1;
        };
    }

    fun assert_public_input_at(public_inputs: &vector<u8>, index: u64, expected: &vector<u8>) {
        assert!(expected.length() == 32, errors::invalid_join_split());
        let start = index * 32;
        let mut i = 0u64;
        while (i < 32) {
            assert!(*public_inputs.borrow(start + i) == *expected.borrow(i), errors::invalid_join_split());
            i = i + 1;
        };
    }

    fun extract_public_input(public_inputs: &vector<u8>, index: u64): vector<u8> {
        let start = index * 32;
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 32) {
            vector::push_back(&mut out, *public_inputs.borrow(start + i));
            i = i + 1;
        };
        out
    }

    fun assert_public_redeem_commitments(
        pool: &Pool,
        n_tree_outputs: u8,
        n_public_outputs: u8,
        commitments_out: &vector<vector<u8>>,
        amounts_sats: &vector<u64>,
    ) {
        let mut i = 0u64;
        while (i < (n_public_outputs as u64)) {
            let amount = *amounts_sats.borrow(i);
            let expected = public_redeem_commitment(pool, amount);
            assert!(
                *commitments_out.borrow((n_tree_outputs as u64) + i) == expected,
                errors::invalid_commitment(),
            );
            i = i + 1;
        };
    }

    fun public_redeem_commitment(pool: &Pool, amount_sats: u64): vector<u8> {
        let commitment = poseidon::poseidon_bn254(&vector[
            0u256,
            pool::btc_token_id(pool),
            (amount_sats as u256),
        ]);
        commitment_tree::field_to_be_bytes(commitment)
    }

    fun compute_redeem_bound_params_hash(
        btc_scripts: &vector<vector<u8>>,
        stealth_data: &vector<vector<u8>>,
    ): vector<u8> {
        let mut scripts = vector[];
        let mut i = 0u64;
        while (i < btc_scripts.length()) {
            vector::append(&mut scripts, *btc_scripts.borrow(i));
            i = i + 1;
        };
        let script_hash = hash::sha2_256(scripts);
        let stealth_hash = compute_stealth_data_hash(stealth_data);

        let mut payload = vector[];
        vector::append(&mut payload, vector[0, 0, 0, 0]);
        vector::push_back(&mut payload, BOUND_PARAMS_REDEEM_FLAG);
        vector::append(&mut payload, script_hash);
        append_u64_le(&mut payload, SUI_BOUND_CHAIN_ID);
        vector::append(&mut payload, stealth_hash);

        let digest = hash::sha2_256(payload);
        commitment_tree::field_to_be_bytes(be_bytes_to_u256(&digest) % BN254_FR)
    }

    fun compute_stealth_data_hash(stealth_data: &vector<vector<u8>>): vector<u8> {
        let mut data = vector[];
        let mut i = 0u64;
        while (i < stealth_data.length()) {
            vector::append(&mut data, *stealth_data.borrow(i));
            i = i + 1;
        };
        hash::sha2_256(data)
    }

    fun append_u64_le(out: &mut vector<u8>, value: u64) {
        let mut i = 0u64;
        while (i < 8) {
            vector::push_back(out, ((value >> ((i * 8) as u8)) & 0xff) as u8);
            i = i + 1;
        };
    }

    fun be_bytes_to_u256(b: &vector<u8>): u256 {
        assert!(b.length() == 32, errors::invalid_commitment());
        let mut acc: u256 = 0;
        let mut i = 0u64;
        while (i < 32) {
            acc = (acc << 8) | (*b.borrow(i) as u256);
            i = i + 1;
        };
        acc
    }

    #[test_only]
    public fun test_public_redeem_commitment(pool: &Pool, amount_sats: u64): vector<u8> {
        public_redeem_commitment(pool, amount_sats)
    }

    #[test_only]
    public fun test_redeem_bound_params_hash(btc_scripts: vector<vector<u8>>): vector<u8> {
        compute_redeem_bound_params_hash(&btc_scripts, &vector[])
    }
}
