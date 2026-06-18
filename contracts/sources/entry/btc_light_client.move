module utxopia::btc_light_client {
    use std::hash;
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_field as df;
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use utxopia::errors;
    use utxopia::events;
    const NETWORK_MAINNET: u8 = 0;
    #[allow(unused_const)]
    const NETWORK_TESTNET3: u8 = 1;
    const NETWORK_TESTNET4: u8 = 2;
    const NETWORK_REGTEST: u8 = 3;
    const HEADER_LEN: u64 = 80;
    const MAX_BATCH_SIZE: u64 = 10;
    const BLOCKS_PER_EPOCH: u64 = 2016;
    const TARGET_TIMESPAN: u64 = 1_209_600;
    const MAX_MERKLE_DEPTH: u64 = 20;
    /// Bitcoin's ~2h future-time bound on header timestamps (in ms, for Sui Clock).
    const MAX_FUTURE_DRIFT_MS: u64 = 2 * 60 * 60 * 1000;
    const MAX_U256: u256 =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    const MAX_TARGET: u256 =
        0x00000000ffff0000000000000000000000000000000000000000000000000000;
    public struct LightClientAdminCap has key { id: UID, light_client_id: ID }
    public struct LightClient has key {
        id: UID,
        network: u8,
        paused: bool,
        required_confirmations: u64,
        tip_hash: vector<u8>,
        tip_height: u64,
        total_chainwork: u256,
        finalized_height: u64,
        expected_bits: u32,
        epoch_start_time: u32,
        genesis_hash: vector<u8>,
        header_count: u64,
        last_update_ms: u64,
    }
    public struct HeaderRecord has store, copy, drop {
        version: u32,
        prev_hash: vector<u8>,
        merkle_root: vector<u8>,
        timestamp: u32,
        bits: u32,
        nonce: u32,
        block_hash: vector<u8>,
        chainwork: u256,
        height: u64,
        expected_bits: u32,
        epoch_start_time: u32,
    }
    public struct HashKey has copy, drop, store { hash: vector<u8> }
    public struct HeightKey has copy, drop, store { height: u64 }
    public struct VerifiedInclusion {
        light_client_id: ID,
        txid: vector<u8>,
        block_hash: vector<u8>,
        block_height: u64,
        merkle_root: vector<u8>,
        tx_index: u32,
    }
    public fun initialize(
        network: u8,
        genesis_raw_header: vector<u8>,
        genesis_height: u64,
        genesis_chainwork: u256,
        genesis_expected_bits: u32,
        genesis_epoch_start_time: u32,
        ctx: &mut TxContext,
    ) {
        assert!(
            network == NETWORK_MAINNET || network == NETWORK_TESTNET4 || network == NETWORK_REGTEST,
            errors::bad_bits(),
        );
        assert!(vector::length(&genesis_raw_header) == HEADER_LEN, errors::bad_header_len());
        let required_confirmations = if (network == NETWORK_MAINNET) { 6 } else { 1 };
        let block_hash = double_sha256(&genesis_raw_header);
        let mut lc = LightClient {
            id: object::new(ctx),
            network,
            paused: false,
            required_confirmations,
            tip_hash: block_hash,
            tip_height: genesis_height,
            total_chainwork: genesis_chainwork,
            finalized_height: saturating_sub(genesis_height, required_confirmations - 1),
            expected_bits: genesis_expected_bits,
            epoch_start_time: genesis_epoch_start_time,
            genesis_hash: block_hash,
            header_count: 1,
            last_update_ms: 0,
        };
        let record = HeaderRecord {
            version: u32_le(&genesis_raw_header, 0),
            prev_hash: slice_bytes(&genesis_raw_header, 4, 36),
            merkle_root: slice_bytes(&genesis_raw_header, 36, 68),
            timestamp: u32_le(&genesis_raw_header, 68),
            bits: u32_le(&genesis_raw_header, 72),
            nonce: u32_le(&genesis_raw_header, 76),
            block_hash,
            chainwork: genesis_chainwork,
            height: genesis_height,
            expected_bits: genesis_expected_bits,
            epoch_start_time: genesis_epoch_start_time,
        };
        store_header(&mut lc, record);
        set_canonical_height(&mut lc, genesis_height, block_hash);
        let cap = LightClientAdminCap { id: object::new(ctx), light_client_id: object::id(&lc) };
        transfer::transfer(cap, tx_context::sender(ctx));
        transfer::share_object(lc);
    }
    public fun set_paused(cap: &LightClientAdminCap, lc: &mut LightClient, paused: bool) {
        assert!(cap.light_client_id == object::id(lc), errors::wrong_cap());
        lc.paused = paused;
    }
    public fun submit_headers(lc: &mut LightClient, raw_headers: vector<u8>, clock: &Clock) {
        assert!(!lc.paused, errors::lc_paused());
        let total = vector::length(&raw_headers);
        assert!(total % HEADER_LEN == 0 && total > 0, errors::bad_header_len());
        let n = total / HEADER_LEN;
        assert!(n <= MAX_BATCH_SIZE, errors::batch_too_large());
        let first_prev = slice_bytes(&raw_headers, 4, 36);
        assert!(has_header(lc, &first_prev), errors::unknown_block());
        let parent = *get_header(lc, &first_prev);
        let mut prev_hash = parent.block_hash;
        let mut running_chainwork = parent.chainwork;
        let mut running_height = parent.height;
        let mut running_expected_bits = parent.expected_bits;
        let mut running_epoch_start = parent.epoch_start_time;
        let mut running_parent_timestamp = parent.timestamp;
        let mut newly_stored = 0u64;
        let mut hashes = vector[];
        let regtest = lc.network == NETWORK_REGTEST;
        let testnet4 = lc.network == NETWORK_TESTNET4;
        // Median Time Past window: timestamps of up to the previous 11 stored blocks
        // (newest first), seeded from `parent`'s chain. Bitcoin consensus requires every
        // block's timestamp to strictly exceed the median of the previous 11 (audit
        // MEDIUM #7). Only maintained for non-regtest networks, which enforce the rule.
        let mut mtp_window = vector[];
        if (!regtest) {
            let mut wh = parent.block_hash;
            let mut more = true;
            while (more && vector::length(&mtp_window) < 11) {
                let r = *get_header(lc, &wh);
                vector::push_back(&mut mtp_window, r.timestamp);
                if (r.height == 0 || !has_header(lc, &r.prev_hash)) {
                    more = false;
                } else {
                    wh = r.prev_hash;
                };
            };
        };
        let mut i = 0;
        while (i < n) {
            let off = i * HEADER_LEN;
            let raw = slice_bytes(&raw_headers, off, off + HEADER_LEN);
            let h_prev = slice_bytes(&raw, 4, 36);
            assert!(h_prev == prev_hash, errors::header_prev_mismatch());
            let timestamp = u32_le(&raw, 68);
            let bits = u32_le(&raw, 72);
            let block_hash = double_sha256(&raw);
            let block_height = running_height + 1;
            if (!regtest) {
                // Reject headers more than ~2h in the future (consensus future-time bound).
                // Closes the testnet4 min-difficulty abuse of arbitrarily-future timestamps.
                let now_ms = clock::timestamp_ms(clock);
                assert!(
                    (timestamp as u64) * 1000 <= now_ms + MAX_FUTURE_DRIFT_MS,
                    errors::timestamp_too_far(),
                );
                // Median Time Past: reject any header whose timestamp is not strictly
                // greater than the median of the previous 11 block timestamps (audit
                // MEDIUM #7). Then slide the window forward so later in-batch headers
                // are checked against the correct, updated set.
                assert!(
                    (timestamp as u64) > (median_timestamp(&mtp_window) as u64),
                    errors::timestamp_not_after_mtp(),
                );
                vector::insert(&mut mtp_window, timestamp, 0);
                if (vector::length(&mtp_window) > 11) { vector::pop_back(&mut mtp_window); };
                let required_bits = required_bits_for_next_block(
                    testnet4,
                    block_height,
                    timestamp,
                    running_parent_timestamp,
                    running_expected_bits,
                    running_epoch_start,
                );
                let target = target_from_bits(bits);
                assert!(hash_meets_target(&block_hash, target), errors::pow_not_met());
                assert!(bits == required_bits, errors::bad_bits());
            };
            let new_chainwork = running_chainwork + work_from_bits(bits);
            if (!regtest && block_height % BLOCKS_PER_EPOCH == 0) {
                running_expected_bits = bits;
                running_epoch_start = timestamp;
            };
            if (!has_header(lc, &block_hash)) {
                let record = HeaderRecord {
                    version: u32_le(&raw, 0),
                    prev_hash,
                    merkle_root: slice_bytes(&raw, 36, 68),
                    timestamp,
                    bits,
                    nonce: u32_le(&raw, 76),
                    block_hash,
                    chainwork: new_chainwork,
                    height: block_height,
                    expected_bits: running_expected_bits,
                    epoch_start_time: running_epoch_start,
                };
                store_header(lc, record);
                newly_stored = newly_stored + 1;
            };
            vector::push_back(&mut hashes, block_hash);
            prev_hash = block_hash;
            running_chainwork = new_chainwork;
            running_height = block_height;
            running_parent_timestamp = timestamp;
            i = i + 1;
        };
        let old_tip_height = lc.tip_height;
        let mut reorg = false;
        if (running_chainwork > lc.total_chainwork) {
            // Determine the TRUE fork point against the current canonical chain: walk back
            // from `parent` along stored ancestors until one matches canonical. A reorg only
            // overwrites heights ABOVE the fork point, so the fork point must be at or above
            // `finalized_height` for every finalized block to stay canonical. Checking only
            // `parent.height` was insufficient: a batch can extend a previously-stored deep
            // side fork whose real divergence point is far below `parent`, letting a heavier
            // branch rewrite finalized history (audit MAJOR #1).
            let mut fork_hash = parent.block_hash;
            let mut fork_height = parent.height;
            let mut finding = true;
            while (finding) {
                if (canonical_hash_at(lc, fork_height) == fork_hash) {
                    finding = false;
                } else if (fork_height == 0 || !has_header(lc, &fork_hash)) {
                    finding = false;
                } else {
                    fork_hash = get_header(lc, &fork_hash).prev_hash;
                    fork_height = fork_height - 1;
                };
            };
            assert!(fork_height >= lc.finalized_height, errors::reorg_below_finalized());
            let mut k = 0;
            while (k < n) {
                set_canonical_height(lc, parent.height + 1 + k, *vector::borrow(&hashes, k));
                k = k + 1;
            };
            let mut anc_hash = parent.block_hash;
            let mut anc_height = parent.height;
            let mut walking = true;
            while (walking) {
                if (canonical_hash_at(lc, anc_height) == anc_hash) {
                    walking = false;
                } else {
                    let prev_anc = get_header(lc, &anc_hash).prev_hash;
                    set_canonical_height(lc, anc_height, anc_hash);
                    if (anc_height == 0 || !has_header(lc, &prev_anc)) {
                        walking = false;
                    } else {
                        anc_hash = prev_anc;
                        anc_height = anc_height - 1;
                    };
                };
            };
            if (running_height < old_tip_height) {
                let mut h = running_height + 1;
                while (h <= old_tip_height) {
                    clear_canonical_height(lc, h);
                    h = h + 1;
                };
            };
            if (parent.height < old_tip_height) { reorg = true; };
            lc.tip_hash = prev_hash;
            lc.tip_height = running_height;
            lc.total_chainwork = running_chainwork;
            // Deepest block with >= required_confirmations is at tip-(required-1) (confs are
            // inclusive). Advance only — never move finality backward on a heavier-but-shorter reorg.
            let candidate = saturating_sub(running_height, lc.required_confirmations - 1);
            if (candidate > lc.finalized_height) {
                lc.finalized_height = candidate;
            };
            if (!regtest) {
                lc.expected_bits = running_expected_bits;
                lc.epoch_start_time = running_epoch_start;
            };
        };
        lc.header_count = lc.header_count + newly_stored;
        lc.last_update_ms = clock::timestamp_ms(clock);
        events::headers_submitted(
            object::uid_to_address(&lc.id),
            lc.tip_hash,
            lc.tip_height,
            lc.total_chainwork,
            reorg,
        );
    }
    public fun confirmations(lc: &LightClient, block_hash: vector<u8>): u64 {
        if (!has_header(lc, &block_hash)) { return 0 };
        let rec = *get_header(lc, &block_hash);
        if (canonical_hash_at(lc, rec.height) != block_hash) { return 0 };
        if (rec.height > lc.tip_height) { 0 } else { lc.tip_height - rec.height + 1 }
    }
    public fun verify_tx_inclusion(
        lc: &LightClient,
        block_hash: vector<u8>,
        txid: vector<u8>,
        tx_index: u32,
        merkle_siblings: vector<vector<u8>>,
        path_bits: u64,
    ): VerifiedInclusion {
        assert!(vector::length(&block_hash) == 32, errors::bad_merkle_proof());
        assert!(vector::length(&txid) == 32, errors::bad_merkle_proof());
        assert!(has_header(lc, &block_hash), errors::unknown_block());
        let rec = *get_header(lc, &block_hash);
        assert!(canonical_hash_at(lc, rec.height) == block_hash, errors::not_canonical());
        let conf = if (rec.height > lc.tip_height) { 0 } else { lc.tip_height - rec.height + 1 };
        assert!(conf >= lc.required_confirmations, errors::insufficient_conf());
        let n_sib = vector::length(&merkle_siblings);
        assert!(n_sib <= MAX_MERKLE_DEPTH, errors::bad_merkle_proof());
        if (n_sib == 0) {
            // A coinbase-only (single-tx) block: the txid IS the merkle root and the only
            // valid leaf index is 0 (audit discussion #39: missing tx_index validation).
            assert!(txid == rec.merkle_root, errors::bad_merkle_proof());
            assert!(tx_index == 0, errors::bad_merkle_proof());
        } else {
            let mut current = txid;
            let mut i = 0;
            while (i < n_sib) {
                let sib = *vector::borrow(&merkle_siblings, i);
                assert!(vector::length(&sib) == 32, errors::bad_merkle_proof());
                let is_left = ((path_bits >> (i as u8)) & 1) == 1;
                // A sibling equal to the current node is legitimate only where Bitcoin
                // duplicates the rightmost node of an odd-width level: that node is the LEFT
                // input and its copy fills the RIGHT slot, so `is_left == false`. Allowing
                // exactly that case fixes false rejection of valid proofs for the last tx of
                // an odd-width level (audit MAJOR #2) while still rejecting the
                // CVE-2012-2459 duplicate-child forgery direction (a node fed as its own
                // LEFT sibling, `is_left == true`).
                if (sib == current) {
                    assert!(!is_left, errors::bad_merkle_proof());
                };
                current = if (is_left) {
                    double_sha256_pair(&sib, &current)
                } else {
                    double_sha256_pair(&current, &sib)
                };
                i = i + 1;
            };
            assert!(current == rec.merkle_root, errors::bad_merkle_proof());
            // path_bits must not assert positions beyond the proof depth, and must equal the
            // declared tx_index (the LE bit pattern IS the leaf index in a Bitcoin merkle proof).
            assert!((path_bits >> (n_sib as u8)) == 0, errors::bad_merkle_proof());
            assert!((tx_index as u64) == path_bits, errors::bad_merkle_proof());
        };
        VerifiedInclusion {
            light_client_id: object::id(lc),
            txid,
            block_hash,
            block_height: rec.height,
            merkle_root: rec.merkle_root,
            tx_index,
        }
    }
    public(package) fun consume_inclusion(
        v: VerifiedInclusion,
    ): (ID, vector<u8>, vector<u8>, u64, vector<u8>, u32) {
        let VerifiedInclusion { light_client_id, txid, block_hash, block_height, merkle_root, tx_index } = v;
        (light_client_id, txid, block_hash, block_height, merkle_root, tx_index)
    }
    #[test_only]
    public fun test_new_inclusion(light_client_id: ID, txid: vector<u8>): VerifiedInclusion {
        VerifiedInclusion {
            light_client_id,
            txid,
            block_hash: vector[],
            block_height: 0,
            merkle_root: vector[],
            tx_index: 0,
        }
    }
    public fun tip_hash(lc: &LightClient): vector<u8> { lc.tip_hash }
    public fun tip_height(lc: &LightClient): u64 { lc.tip_height }
    public fun total_chainwork(lc: &LightClient): u256 { lc.total_chainwork }
    public fun finalized_height(lc: &LightClient): u64 { lc.finalized_height }
    public fun network(lc: &LightClient): u8 { lc.network }
    public fun is_paused(lc: &LightClient): bool { lc.paused }
    public fun header_count(lc: &LightClient): u64 { lc.header_count }
    public fun required_confirmations(lc: &LightClient): u64 { lc.required_confirmations }
    fun store_header(lc: &mut LightClient, record: HeaderRecord) {
        df::add(&mut lc.id, HashKey { hash: record.block_hash }, record);
    }
    fun has_header(lc: &LightClient, hash: &vector<u8>): bool {
        df::exists(&lc.id, HashKey { hash: *hash })
    }
    fun get_header(lc: &LightClient, hash: &vector<u8>): &HeaderRecord {
        df::borrow<HashKey, HeaderRecord>(&lc.id, HashKey { hash: *hash })
    }
    fun set_canonical_height(lc: &mut LightClient, height: u64, hash: vector<u8>) {
        let key = HeightKey { height };
        if (df::exists(&lc.id, key)) {
            let slot = df::borrow_mut<HeightKey, vector<u8>>(&mut lc.id, key);
            *slot = hash;
        } else {
            df::add(&mut lc.id, key, hash);
        }
    }
    fun clear_canonical_height(lc: &mut LightClient, height: u64) {
        let key = HeightKey { height };
        if (df::exists(&lc.id, key)) {
            let _: vector<u8> = df::remove(&mut lc.id, key);
        }
    }
    fun canonical_hash_at(lc: &LightClient, height: u64): vector<u8> {
        let key = HeightKey { height };
        if (df::exists(&lc.id, key)) {
            *df::borrow<HeightKey, vector<u8>>(&lc.id, key)
        } else {
            vector[]
        }
    }
    fun double_sha256(data: &vector<u8>): vector<u8> {
        hash::sha2_256(hash::sha2_256(*data))
    }
    fun double_sha256_pair(left: &vector<u8>, right: &vector<u8>): vector<u8> {
        let mut buf = *left;
        vector::append(&mut buf, *right);
        double_sha256(&buf)
    }
    fun target_from_bits(bits: u32): u256 {
        let exp = ((bits >> 24) & 0xff) as u64;
        let mantissa = (bits & 0x007fffff) as u256;
        if (exp <= 3) {
            mantissa >> ((8 * (3 - exp)) as u8)
        } else if (exp > 32) {
            0
        } else {
            mantissa << ((8 * (exp - 3)) as u8)
        }
    }
    fun bits_from_target(target: u256): u32 {
        let size = target_byte_size(target);
        let compact = if (size <= 3) {
            target << ((8 * (3 - size)) as u8)
        } else {
            target >> ((8 * (size - 3)) as u8)
        };
        let mut compact32 = ((compact & 0xffffff) as u32);
        let mut size_final = size;
        if ((compact32 & 0x00800000) != 0) {
            compact32 = compact32 >> 8;
            size_final = size + 1;
        };
        compact32 | ((size_final as u32) << 24)
    }
    fun target_byte_size(t: u256): u64 {
        let mut v = t;
        let mut size = 0u64;
        while (v > 0) {
            v = v >> 8;
            size = size + 1;
        };
        size
    }
    fun work_from_bits(bits: u32): u256 {
        let target = target_from_bits(bits);
        if (target == 0) { return 0 };
        let tp1 = target + 1;
        (MAX_U256 - target) / tp1 + 1
    }
    fun hash_meets_target(block_hash: &vector<u8>, target: u256): bool {
        le_bytes_to_u256(block_hash) <= target
    }
    fun calculate_new_bits(old_bits: u32, actual_timespan: u32): u32 {
        let low = TARGET_TIMESPAN / 4;
        let high = TARGET_TIMESPAN * 4;
        let mut t = (actual_timespan as u64);
        if (t < low) { t = low };
        if (t > high) { t = high };
        let old_target = target_from_bits(old_bits);
        let new_target = old_target * (t as u256) / (TARGET_TIMESPAN as u256);
        let capped = if (new_target > MAX_TARGET) { MAX_TARGET } else { new_target };
        bits_from_target(capped)
    }
    fun required_bits_for_next_block(
        testnet4: bool,
        block_height: u64,
        timestamp: u32,
        parent_timestamp: u32,
        epoch_bits: u32,
        epoch_start_time: u32,
    ): u32 {
        if (epoch_bits == 0) {
            return 0
        };
        if (block_height % BLOCKS_PER_EPOCH == 0) {
            // A backward epoch timestamp is a negative timespan in Bitcoin Core, which clamps
            // to the LOW bound (TARGET/4, difficulty increase). Feeding 0 into calculate_new_bits
            // hits that same low clamp; wrapping into a huge u32 would wrongly pick the HIGH clamp.
            let actual = if (epoch_start_time == 0) {
                TARGET_TIMESPAN as u32
            } else if (parent_timestamp >= epoch_start_time) {
                parent_timestamp - epoch_start_time
            } else {
                0
            };
            return calculate_new_bits(epoch_bits, actual)
        };
        // Bitcoin's testnet min-difficulty rule is the non-wrapping comparison
        // `child_time > parent_time + 1200`. A child whose timestamp is <= its
        // parent's must NOT trigger the exception; the `timestamp > parent_timestamp`
        // guard keeps the subtraction from underflowing into a huge u32.
        if (testnet4 && timestamp > parent_timestamp && (timestamp - parent_timestamp) > 1200) {
            return bits_from_target(MAX_TARGET)
        };
        epoch_bits
    }
    fun u32_le(data: &vector<u8>, off: u64): u32 {
        (*vector::borrow(data, off) as u32)
            | ((*vector::borrow(data, off + 1) as u32) << 8)
            | ((*vector::borrow(data, off + 2) as u32) << 16)
            | ((*vector::borrow(data, off + 3) as u32) << 24)
    }
    fun le_bytes_to_u256(b: &vector<u8>): u256 {
        assert!(vector::length(b) == 32, errors::bad_merkle_proof());
        let mut acc: u256 = 0;
        let mut i = 0;
        while (i < 32) {
            acc = acc | ((*vector::borrow(b, i) as u256) << ((8 * i) as u8));
            i = i + 1;
        };
        acc
    }
    fun slice_bytes(data: &vector<u8>, start: u64, end: u64): vector<u8> {
        let mut out = vector[];
        let mut i = start;
        while (i < end) {
            vector::push_back(&mut out, *vector::borrow(data, i));
            i = i + 1;
        };
        out
    }
    fun saturating_sub(a: u64, b: u64): u64 {
        if (a >= b) { a - b } else { 0 }
    }
    /// Median of up to 11 recent block timestamps (Bitcoin's Median Time Past). Sorts a
    /// copy ascending (n <= 11, so an O(n^2) selection sort is fine) and returns the
    /// middle element. With fewer than 11 ancestors (near genesis) it uses what is
    /// available, matching Bitcoin's behaviour at low heights.
    fun median_timestamp(window: &vector<u32>): u32 {
        let n = vector::length(window);
        let mut sorted = *window;
        let mut a = 0u64;
        while (a < n) {
            let mut b = a + 1;
            while (b < n) {
                if (*vector::borrow(&sorted, b) < *vector::borrow(&sorted, a)) {
                    vector::swap(&mut sorted, a, b);
                };
                b = b + 1;
            };
            a = a + 1;
        };
        *vector::borrow(&sorted, n / 2)
    }
    #[test_only]
    public fun test_double_sha256(data: vector<u8>): vector<u8> { double_sha256(&data) }
    #[test_only]
    public fun test_target_from_bits(bits: u32): u256 { target_from_bits(bits) }
    #[test_only]
    public fun test_bits_from_target(target: u256): u32 { bits_from_target(target) }
    #[test_only]
    public fun test_work_from_bits(bits: u32): u256 { work_from_bits(bits) }
    #[test_only]
    public fun test_hash_meets_target(block_hash: vector<u8>, target: u256): bool {
        hash_meets_target(&block_hash, target)
    }
    #[test_only]
    public fun test_calculate_new_bits(old_bits: u32, actual: u32): u32 {
        calculate_new_bits(old_bits, actual)
    }
    #[test_only]
    public fun test_required_bits_for_next_block(
        testnet4: bool,
        block_height: u64,
        timestamp: u32,
        parent_timestamp: u32,
        epoch_bits: u32,
        epoch_start_time: u32,
    ): u32 {
        required_bits_for_next_block(
            testnet4,
            block_height,
            timestamp,
            parent_timestamp,
            epoch_bits,
            epoch_start_time,
        )
    }
    #[test_only]
    public fun test_max_target(): u256 { MAX_TARGET }
    /// Initialize a REGTEST light client with a custom required_confirmations
    /// value, allowing tests to exercise finality semantics that are not
    /// reachable through the normal `initialize` entry (which always uses 1 for
    /// non-mainnet networks).
    #[test_only]
    public fun test_initialize_with_confirmations(
        genesis_raw_header: vector<u8>,
        genesis_height: u64,
        genesis_chainwork: u256,
        genesis_expected_bits: u32,
        genesis_epoch_start_time: u32,
        required_confirmations: u64,
        ctx: &mut TxContext,
    ) {
        assert!(vector::length(&genesis_raw_header) == HEADER_LEN, errors::bad_header_len());
        let block_hash = double_sha256(&genesis_raw_header);
        let mut lc = LightClient {
            id: object::new(ctx),
            network: NETWORK_REGTEST,
            paused: false,
            required_confirmations,
            tip_hash: block_hash,
            tip_height: genesis_height,
            total_chainwork: genesis_chainwork,
            finalized_height: saturating_sub(genesis_height, if (required_confirmations > 0) { required_confirmations - 1 } else { 0 }),
            expected_bits: genesis_expected_bits,
            epoch_start_time: genesis_epoch_start_time,
            genesis_hash: block_hash,
            header_count: 1,
            last_update_ms: 0,
        };
        let record = HeaderRecord {
            version: u32_le(&genesis_raw_header, 0),
            prev_hash: slice_bytes(&genesis_raw_header, 4, 36),
            merkle_root: slice_bytes(&genesis_raw_header, 36, 68),
            timestamp: u32_le(&genesis_raw_header, 68),
            bits: u32_le(&genesis_raw_header, 72),
            nonce: u32_le(&genesis_raw_header, 76),
            block_hash,
            chainwork: genesis_chainwork,
            height: genesis_height,
            expected_bits: genesis_expected_bits,
            epoch_start_time: genesis_epoch_start_time,
        };
        store_header(&mut lc, record);
        set_canonical_height(&mut lc, genesis_height, block_hash);
        let cap = LightClientAdminCap { id: object::new(ctx), light_client_id: object::id(&lc) };
        transfer::transfer(cap, tx_context::sender(ctx));
        transfer::share_object(lc);
    }
}
