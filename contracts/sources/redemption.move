module utxopia::redemption {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use utxopia::bitcoin;
    use utxopia::btc_light_client::{Self, VerifiedInclusion};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, Pool};
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    const MAX_PUBLIC_REDEMPTIONS: u8 = 3;

    /// Authority over exactly one RedemptionQueue (bound by `queue_id`).
    public struct RedemptionCap has key {
        id: UID,
        queue_id: ID,
    }

    public struct RedemptionQueue has key {
        id: UID,
        requests: vector<RedemptionRequest>,
    }

    public struct RedemptionRequest has store, drop {
        id: u64,
        pool_id: address,
        /// Raw destination scriptPubKey (NOT a hash / bech32). Pins the destination so
        /// completion can byte-compare it against the SPV-verified broadcast output.
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
        completed: bool,
    }

    public fun initialize_queue(ctx: &mut TxContext) {
        let queue = RedemptionQueue {
            id: object::new(ctx),
            requests: vector[],
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
    ) {
        pool::assert_not_paused(pool);
        enqueue_redemption_request(pool, queue, btc_script, amount_sats, max_fee_sats);
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
        assert_bound_public_inputs(&public_inputs, n_inputs, n_outputs, &nullifiers_in, &commitments_out);

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

        let mut i = 0;
        while (i < nullifiers_in.length()) {
            nullifier::record_spend(pool_id, nullifiers, nullifiers_in[i]);
            i = i + 1;
        };

        let n_tree_outputs = n_outputs - n_public_outputs;
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
            enqueue_redemption_request(pool, queue, btc_script, amount_sats, max_fee_sats);
            k = k + 1;
        };
        pool::record_redemption_request(pool, total_redeemed);
    }

    public fun complete_redemption(
        cap: &RedemptionCap,
        pool: &Pool,
        queue: &mut RedemptionQueue,
        redemption_id: u64,
        inclusion: VerifiedInclusion,
        raw_tx: vector<u8>,
    ) {
        assert_cap(cap, queue);
        let request = borrow_request_mut(queue, redemption_id);
        assert!(!request.completed, errors::redemption_completed());
        assert!(request.pool_id == pool::pool_id(pool), errors::invalid_redemption());

        let (light_client_id, btc_txid, _block_hash, _height, _merkle_root, _tx_index) =
            btc_light_client::consume_inclusion(inclusion);
        pool::assert_light_client(pool, light_client_id);
        assert!(bitcoin::double_sha256(&raw_tx) == btc_txid, errors::invalid_redemption());

        let (found, output, _vout) = bitcoin::find_output_by_script(&raw_tx, &request.btc_script);
        assert!(found, errors::invalid_redemption());
        assert!(bitcoin::output_value(&output) == request.amount_sats, errors::invalid_redemption());

        request.completed = true;
        events::redemption_completed(pool::pool_id(pool), redemption_id, btc_txid);
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
        let mut i = 0;
        let len = vector::length(&queue.requests);
        while (i < len) {
            let request = vector::borrow(&queue.requests, i);
            if (request.id == redemption_id) {
                return request
            };
            i = i + 1;
        };
        abort errors::invalid_redemption()
    }

    fun borrow_request_mut(queue: &mut RedemptionQueue, redemption_id: u64): &mut RedemptionRequest {
        let mut i = 0;
        let len = vector::length(&queue.requests);
        while (i < len) {
            let request = vector::borrow_mut(&mut queue.requests, i);
            if (request.id == redemption_id) {
                return request
            };
            i = i + 1;
        };
        abort errors::invalid_redemption()
    }

    fun enqueue_redemption_request(
        pool: &mut Pool,
        queue: &mut RedemptionQueue,
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
    ): u64 {
        assert!(amount_sats > 0, errors::invalid_redemption());
        assert!(vector::length(&btc_script) > 0, errors::invalid_redemption());

        let redemption_id = pool::allocate_redemption_id(pool);
        let pool_id = pool::pool_id(pool);
        vector::push_back(&mut queue.requests, RedemptionRequest {
            id: redemption_id,
            pool_id,
            btc_script,
            amount_sats,
            max_fee_sats,
            completed: false,
        });

        let request = vector::borrow(&queue.requests, vector::length(&queue.requests) - 1);
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

        let mut i = 0;
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
        let mut i = 0;
        while (i < 32) {
            assert!(*public_inputs.borrow(start + i) == *expected.borrow(i), errors::invalid_join_split());
            i = i + 1;
        };
    }

    fun extract_public_input(public_inputs: &vector<u8>, index: u64): vector<u8> {
        let start = index * 32;
        let mut out = vector[];
        let mut i = 0;
        while (i < 32) {
            vector::push_back(&mut out, *public_inputs.borrow(start + i));
            i = i + 1;
        };
        out
    }
}
