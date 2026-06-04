/// Bitcoin SPV light client (Move port of the Solana `btc-light-client` program).
///
/// Stores a checkpoint-anchored header chain, validates submitted headers (double-SHA256
/// PoW vs `bits`, difficulty-matches-expected, chain continuity, 2016-block retarget),
/// resolves reorgs by cumulative chainwork, and exposes `verify_tx_inclusion`, which
/// returns a hot-potato `VerifiedInclusion` that the deposit module consumes in the same
/// PTB. Native `u256` replaces Solana's 4×u64 limb math; `std::hash::sha2_256` is the
/// double-SHA256 primitive.
///
/// NOTE: the legacy `VerifiedBtcDeposit` shim (no verification) is retained TEMPORARILY so
/// `btc_deposit` still compiles; module 04 (complete-deposit wiring) routes deposits through
/// `verify_tx_inclusion` and DELETES the shim, closing the forgeable-deposit hole.
module utxopia::btc_light_client {
    use std::hash;
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_field as df;
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use utxopia::errors;
    use utxopia::events;

    // --- network ids ---
    const NETWORK_MAINNET: u8 = 0;
    const NETWORK_REGTEST: u8 = 2;

    // --- consensus constants ---
    const HEADER_LEN: u64 = 80;
    const MAX_BATCH_SIZE: u64 = 10;
    const BLOCKS_PER_EPOCH: u64 = 2016;
    const TARGET_TIMESPAN: u64 = 1_209_600; // 2 weeks in seconds
    const MAX_MERKLE_DEPTH: u64 = 20;

    /// 2^256 - 1.
    const MAX_U256: u256 =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    /// target_from_bits(0x1d00ffff): the difficulty-1 / max mainnet target.
    const MAX_TARGET: u256 =
        0x00000000ffff0000000000000000000000000000000000000000000000000000;

    // =====================================================================
    // Light client
    // =====================================================================

    public struct LightClientAdminCap has key { id: UID, light_client_id: ID }

    /// Shared singleton. One per deployment.
    public struct LightClient has key {
        id: UID,
        network: u8,
        paused: bool,
        required_confirmations: u64,
        // canonical tip
        tip_hash: vector<u8>,
        tip_height: u64,
        total_chainwork: u256,
        finalized_height: u64,
        // difficulty tracking for the canonical chain
        expected_bits: u32,
        epoch_start_time: u32,
        // bookkeeping
        genesis_hash: vector<u8>,
        header_count: u64,
        last_update_ms: u64,
    }

    /// Stored per accepted header (canonical OR side fork). Carries difficulty params as
    /// of this block so a fork from an old parent re-derives difficulty correctly.
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

    /// Hot potato (no abilities): the caller MUST consume it in the same PTB via the
    /// package-only `consume_inclusion`. Proves a txid is merkle-included in a canonical,
    /// sufficiently-confirmed block.
    public struct VerifiedInclusion {
        txid: vector<u8>,
        block_hash: vector<u8>,
        block_height: u64,
        merkle_root: vector<u8>,
        tx_index: u32,
    }

    // ---------------------------------------------------------------------
    // Init / admin
    // ---------------------------------------------------------------------

    /// Bootstrap from a trusted checkpoint header (NOT block 0) to keep the chain short.
    /// The checkpoint's chainwork/height/difficulty are the single accepted trust root.
    public fun initialize(
        network: u8,
        genesis_raw_header: vector<u8>,
        genesis_height: u64,
        genesis_chainwork: u256,
        genesis_expected_bits: u32,
        genesis_epoch_start_time: u32,
        ctx: &mut TxContext,
    ) {
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
            finalized_height: saturating_sub(genesis_height, required_confirmations),
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

    // ---------------------------------------------------------------------
    // Header submission (port of extend_blockchain.rs)
    // ---------------------------------------------------------------------

    /// Permissionless. Submit 1..=MAX_BATCH_SIZE consecutive headers building on an
    /// existing stored parent (canonical tip OR any stored fork block).
    public fun submit_headers(lc: &mut LightClient, raw_headers: vector<u8>, clock: &Clock) {
        assert!(!lc.paused, errors::lc_paused());
        let total = vector::length(&raw_headers);
        assert!(total % HEADER_LEN == 0 && total > 0, errors::bad_header_len());
        let n = total / HEADER_LEN;
        assert!(n <= MAX_BATCH_SIZE, errors::batch_too_large());

        // Resolve parent from the first header's prev_hash.
        let first_prev = slice_bytes(&raw_headers, 4, 36);
        assert!(has_header(lc, &first_prev), errors::unknown_block());
        let parent = *get_header(lc, &first_prev);

        let mut prev_hash = parent.block_hash;
        let mut running_chainwork = parent.chainwork;
        let mut running_height = parent.height;
        let mut running_expected_bits = parent.expected_bits;
        let mut running_epoch_start = parent.epoch_start_time;

        let mut newly_stored = 0u64;
        let mut hashes = vector[];
        let regtest = lc.network == NETWORK_REGTEST;

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
                let target = target_from_bits(bits);
                assert!(hash_meets_target(&block_hash, target), errors::pow_not_met());
                assert!(
                    running_expected_bits == 0 || bits == running_expected_bits,
                    errors::bad_bits(),
                );
            };

            let new_chainwork = running_chainwork + work_from_bits(bits);

            // Difficulty retarget at the epoch boundary.
            if (!regtest && block_height % BLOCKS_PER_EPOCH == 0) {
                if (running_epoch_start != 0 && running_expected_bits != 0) {
                    let actual = wrapping_sub_u32(timestamp, running_epoch_start);
                    running_expected_bits = calculate_new_bits(running_expected_bits, actual);
                };
                running_epoch_start = timestamp;
            };

            // Idempotent: skip storing a header we already have, but still advance state.
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
            i = i + 1;
        };

        // Canonical decision by strictly-greater cumulative chainwork (ties keep incumbent).
        let old_tip_height = lc.tip_height;
        let mut reorg = false;
        if (running_chainwork > lc.total_chainwork) {
            let mut k = 0;
            while (k < n) {
                set_canonical_height(lc, parent.height + 1 + k, *vector::borrow(&hashes, k));
                k = k + 1;
            };
            // R3: a shorter-but-heavier fork must invalidate stale upper canonical heights.
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
            lc.finalized_height = saturating_sub(running_height, lc.required_confirmations);
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

    // ---------------------------------------------------------------------
    // Inclusion / confirmations (port of verify_transaction.rs)
    // ---------------------------------------------------------------------

    /// Confirmations for a canonical block hash (0 if unknown or not on the canonical chain).
    public fun confirmations(lc: &LightClient, block_hash: vector<u8>): u64 {
        if (!has_header(lc, &block_hash)) { return 0 };
        let rec = *get_header(lc, &block_hash);
        if (canonical_hash_at(lc, rec.height) != block_hash) { return 0 };
        if (rec.height > lc.tip_height) { 0 } else { lc.tip_height - rec.height + 1 }
    }

    /// Verify `txid` is merkle-included in a canonical, sufficiently-confirmed block.
    /// `path_bits` bit i set => sibling i is on the LEFT (current is the right child),
    /// matching Solana `verify_transaction.rs`. Aborts on any failure.
    public fun verify_tx_inclusion(
        lc: &LightClient,
        block_hash: vector<u8>,
        txid: vector<u8>,
        tx_index: u32,
        merkle_siblings: vector<vector<u8>>,
        path_bits: u64,
    ): VerifiedInclusion {
        // Reject malformed proofs up front: Bitcoin hashes are fixed 32-byte values.
        assert!(vector::length(&block_hash) == 32, errors::bad_merkle_proof());
        assert!(vector::length(&txid) == 32, errors::bad_merkle_proof());
        assert!(has_header(lc, &block_hash), errors::unknown_block());
        let rec = *get_header(lc, &block_hash);

        // Canonical check (stronger than Solana): the height index must point at this block.
        assert!(canonical_hash_at(lc, rec.height) == block_hash, errors::not_canonical());

        let conf = if (rec.height > lc.tip_height) { 0 } else { lc.tip_height - rec.height + 1 };
        assert!(conf >= lc.required_confirmations, errors::insufficient_conf());

        let n_sib = vector::length(&merkle_siblings);
        assert!(n_sib <= MAX_MERKLE_DEPTH, errors::bad_merkle_proof());
        if (n_sib == 0) {
            // single-tx block: the txid IS the merkle root.
            assert!(txid == rec.merkle_root, errors::bad_merkle_proof());
        } else {
            let mut current = txid;
            let mut i = 0;
            while (i < n_sib) {
                let sib = *vector::borrow(&merkle_siblings, i);
                assert!(vector::length(&sib) == 32, errors::bad_merkle_proof());
                let is_left = ((path_bits >> (i as u8)) & 1) == 1;
                current = if (is_left) {
                    double_sha256_pair(&sib, &current)
                } else {
                    double_sha256_pair(&current, &sib)
                };
                i = i + 1;
            };
            assert!(current == rec.merkle_root, errors::bad_merkle_proof());
        };

        VerifiedInclusion {
            txid,
            block_hash,
            block_height: rec.height,
            merkle_root: rec.merkle_root,
            tx_index,
        }
    }

    /// Package-only unpack for the deposit module.
    public(package) fun consume_inclusion(
        v: VerifiedInclusion,
    ): (vector<u8>, vector<u8>, u64, vector<u8>, u32) {
        let VerifiedInclusion { txid, block_hash, block_height, merkle_root, tx_index } = v;
        (txid, block_hash, block_height, merkle_root, tx_index)
    }

    // ---------------------------------------------------------------------
    // Read accessors
    // ---------------------------------------------------------------------

    public fun tip_hash(lc: &LightClient): vector<u8> { lc.tip_hash }
    public fun tip_height(lc: &LightClient): u64 { lc.tip_height }
    public fun total_chainwork(lc: &LightClient): u256 { lc.total_chainwork }
    public fun finalized_height(lc: &LightClient): u64 { lc.finalized_height }
    public fun network(lc: &LightClient): u8 { lc.network }
    public fun is_paused(lc: &LightClient): bool { lc.paused }
    public fun header_count(lc: &LightClient): u64 { lc.header_count }
    public fun required_confirmations(lc: &LightClient): u64 { lc.required_confirmations }

    // ---------------------------------------------------------------------
    // Header / height-index storage (dynamic fields)
    // ---------------------------------------------------------------------

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

    // ---------------------------------------------------------------------
    // Hashing
    // ---------------------------------------------------------------------

    fun double_sha256(data: &vector<u8>): vector<u8> {
        hash::sha2_256(hash::sha2_256(*data))
    }

    fun double_sha256_pair(left: &vector<u8>, right: &vector<u8>): vector<u8> {
        let mut buf = *left;
        vector::append(&mut buf, *right);
        double_sha256(&buf)
    }

    // ---------------------------------------------------------------------
    // PoW / target / chainwork / retarget (port of pow.rs + difficulty.rs)
    // ---------------------------------------------------------------------

    /// Decode compact `bits` into a 256-bit target. Oversized exponents yield 0 (no hash passes).
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

    /// Encode a target back into compact `bits` (port of difficulty.rs sign-bit handling).
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

    /// work = 2^256 / (target + 1), computed without overflow as (MAX - target)/(target+1) + 1.
    fun work_from_bits(bits: u32): u256 {
        let target = target_from_bits(bits);
        if (target == 0) { return 0 };
        let tp1 = target + 1;
        (MAX_U256 - target) / tp1 + 1
    }

    /// Bitcoin targets/hashes are little-endian 256-bit; hash passes iff numeric value <= target.
    fun hash_meets_target(block_hash: &vector<u8>, target: u256): bool {
        le_bytes_to_u256(block_hash) <= target
    }

    /// new_target = clamp(actual, TS/4, TS*4) * old_target / TS, capped at MAX_TARGET.
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

    // ---------------------------------------------------------------------
    // Byte / integer helpers
    // ---------------------------------------------------------------------

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

    /// Matches Rust `u32::wrapping_sub` so retarget math is byte-identical to Solana.
    fun wrapping_sub_u32(a: u32, b: u32): u32 {
        if (a >= b) {
            a - b
        } else {
            (((a as u64) + 0x1_0000_0000 - (b as u64)) as u32)
        }
    }

    fun saturating_sub(a: u64, b: u64): u64 {
        if (a >= b) { a - b } else { 0 }
    }

    // ---------------------------------------------------------------------
    // Test-only accessors
    // ---------------------------------------------------------------------

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
    public fun test_wrapping_sub_u32(a: u32, b: u32): u32 { wrapping_sub_u32(a, b) }
    #[test_only]
    public fun test_max_target(): u256 { MAX_TARGET }
}
