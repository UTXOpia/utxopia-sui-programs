module utxopia::redemption {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, Pool};

    public struct RedemptionCap has key {
        id: UID,
    }

    public struct RedemptionQueue has key {
        id: UID,
        requests: vector<RedemptionRequest>,
    }

    public struct RedemptionRequest has store, drop {
        id: u64,
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
        let cap = RedemptionCap { id: object::new(ctx) };

        transfer::share_object(queue);
        transfer::transfer(cap, sui::tx_context::sender(ctx));
    }

    public fun request_redemption(
        _: &RedemptionCap,
        pool: &mut Pool,
        queue: &mut RedemptionQueue,
        btc_script: vector<u8>,
        amount_sats: u64,
        max_fee_sats: u64,
    ) {
        pool::assert_not_paused(pool);
        assert!(amount_sats > 0, errors::invalid_redemption());
        assert!(vector::length(&btc_script) > 0, errors::invalid_redemption());

        let redemption_id = pool::allocate_redemption_id(pool);
        vector::push_back(&mut queue.requests, RedemptionRequest {
            id: redemption_id,
            btc_script,
            amount_sats,
            max_fee_sats,
            completed: false,
        });

        let request = vector::borrow(&queue.requests, vector::length(&queue.requests) - 1);
        events::redemption_requested(
            pool::pool_id(pool),
            redemption_id,
            request.btc_script,
            amount_sats,
            max_fee_sats,
        );
    }

    public fun complete_redemption(
        _: &RedemptionCap,
        pool: &Pool,
        queue: &mut RedemptionQueue,
        redemption_id: u64,
        btc_txid: vector<u8>,
    ) {
        let request = borrow_request_mut(queue, redemption_id);
        assert!(!request.completed, errors::redemption_completed());
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
}
