module utxopia::bound_params {
    use std::hash;
    use std::type_name;
    use sui::poseidon;
    use utxopia::commitment_tree;
    use utxopia::errors;
    const SUI_BOUND_CHAIN_ID: u64 = 784;
    const BOUND_PARAMS_TRANSFER_FLAG: u8 = 0;
    const BOUND_PARAMS_UNSHIELD_FLAG: u8 = 1;
    const BOUND_PARAMS_REDEEM_FLAG: u8 = 2;
    const BN254_FR: u256 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    public(package) fun transfer_hash(stealth_data: &vector<vector<u8>>): vector<u8> {
        let stealth_hash = stealth_data_hash(stealth_data);
        let mut payload = vector[];
        vector::append(&mut payload, vector[0, 0, 0, 0]);
        vector::push_back(&mut payload, BOUND_PARAMS_TRANSFER_FLAG);
        let mut k = 0u64;
        while (k < 32) {
            vector::push_back(&mut payload, 0u8);
            k = k + 1;
        };
        append_u64_le(&mut payload, SUI_BOUND_CHAIN_ID);
        vector::append(&mut payload, stealth_hash);
        finalize(payload)
    }
    public(package) fun redeem_hash(
        btc_scripts: &vector<vector<u8>>,
        stealth_data: &vector<vector<u8>>,
    ): vector<u8> {
        // Bind the scripts with explicit boundaries (count + per-script length) so a proof
        // cannot be replayed with a different partitioning of the same concatenated bytes
        // (audit MAJOR #4 / #53).
        let script_hash = length_prefixed_hash(btc_scripts);
        let stealth_hash = stealth_data_hash(stealth_data);
        let mut payload = vector[];
        vector::append(&mut payload, vector[0, 0, 0, 0]);
        vector::push_back(&mut payload, BOUND_PARAMS_REDEEM_FLAG);
        vector::append(&mut payload, script_hash);
        append_u64_le(&mut payload, SUI_BOUND_CHAIN_ID);
        vector::append(&mut payload, stealth_hash);
        finalize(payload)
    }
    public(package) fun unshield_hash(
        recipients: &vector<address>,
        stealth_data: &vector<vector<u8>>,
    ): vector<u8> {
        // Bind recipients with explicit boundaries (count + per-item length) so the proof
        // commits to the exact recipient set and ordering (audit #51/#52 family).
        let mut addr_items = vector[];
        let mut i = 0u64;
        while (i < recipients.length()) {
            vector::push_back(&mut addr_items, std::bcs::to_bytes(recipients.borrow(i)));
            i = i + 1;
        };
        let recipients_hash = length_prefixed_hash(&addr_items);
        let stealth_hash = stealth_data_hash(stealth_data);
        let mut payload = vector[];
        vector::append(&mut payload, vector[0, 0, 0, 0]);
        vector::push_back(&mut payload, BOUND_PARAMS_UNSHIELD_FLAG);
        vector::append(&mut payload, recipients_hash);
        append_u64_le(&mut payload, SUI_BOUND_CHAIN_ID);
        vector::append(&mut payload, stealth_hash);
        finalize(payload)
    }
    public(package) fun sui_token_id<T>(): u256 {
        let type_bytes = type_name::with_defining_ids<T>().into_string().into_bytes();
        let digest = hash::sha2_256(type_bytes);
        let field = be_bytes_to_u256(&digest) % BN254_FR;
        poseidon::poseidon_bn254(&vector[field, 0u256])
    }
    fun finalize(payload: vector<u8>): vector<u8> {
        let digest = hash::sha2_256(payload);
        commitment_tree::field_to_be_bytes(be_bytes_to_u256(&digest) % BN254_FR)
    }
    fun stealth_data_hash(stealth_data: &vector<vector<u8>>): vector<u8> {
        // Length-prefixed so entries of different sizes can't be re-sliced to the same hash
        // (audit #51/#52/#54: ambiguous stealth-data concatenation).
        length_prefixed_hash(stealth_data)
    }
    /// Hash a list of byte-strings with explicit boundaries so no two distinct lists can
    /// collide: sha256( u32_le(count) || for each item [ u32_le(len) || item ] ).
    fun length_prefixed_hash(items: &vector<vector<u8>>): vector<u8> {
        let mut buf = vector[];
        append_u32_le(&mut buf, (vector::length(items) as u32));
        let mut i = 0u64;
        while (i < vector::length(items)) {
            let item = vector::borrow(items, i);
            append_u32_le(&mut buf, (vector::length(item) as u32));
            vector::append(&mut buf, *item);
            i = i + 1;
        };
        hash::sha2_256(buf)
    }
    fun append_u32_le(out: &mut vector<u8>, value: u32) {
        let mut i = 0u64;
        while (i < 4) {
            vector::push_back(out, ((value >> ((i * 8) as u8)) & 0xff) as u8);
            i = i + 1;
        };
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
    public fun test_transfer_hash(stealth_data: vector<vector<u8>>): vector<u8> {
        transfer_hash(&stealth_data)
    }
    #[test_only]
    public fun test_redeem_hash(
        btc_scripts: vector<vector<u8>>,
        stealth_data: vector<vector<u8>>,
    ): vector<u8> {
        redeem_hash(&btc_scripts, &stealth_data)
    }
    #[test_only]
    public fun test_unshield_hash(
        recipients: vector<address>,
        stealth_data: vector<vector<u8>>,
    ): vector<u8> {
        unshield_hash(&recipients, &stealth_data)
    }
    #[test_only]
    public fun test_sui_token_id<T>(): u256 {
        sui_token_id<T>()
    }
}
