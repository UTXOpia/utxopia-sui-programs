module utxopia::verifier {
    use sui::groth16;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use utxopia::errors;
    use utxopia::events;
    use utxopia::pool::{Self, AdminCap, Pool};

    const MAX_SUI_PUBLIC_INPUTS: u8 = 8;
    const VK_HASH_LEN: u64 = 32;

    public struct VerifyingKeyRegistry has key {
        id: UID,
        keys: vector<VerifyingKeyEntry>,
    }

    public struct VerifyingKeyEntry has copy, drop, store {
        n_inputs: u8,
        n_outputs: u8,
        n_public: u8,
        vk_hash: vector<u8>,
        prepared_vk: groth16::PreparedVerifyingKey,
    }

    public fun initialize_registry(ctx: &mut TxContext) {
        transfer::share_object(VerifyingKeyRegistry {
            id: object::new(ctx),
            keys: vector[],
        });
    }

    public fun register_prepared_key(
        cap: &AdminCap,
        pool: &Pool,
        registry: &mut VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        n_public: u8,
        vk_hash: vector<u8>,
        vk_gamma_abc_g1_bytes: vector<u8>,
        alpha_g1_beta_g2_bytes: vector<u8>,
        gamma_g2_neg_pc_bytes: vector<u8>,
        delta_g2_neg_pc_bytes: vector<u8>,
    ) {
        pool::assert_admin(cap, pool);
        pool::assert_vk_registry(pool, object::id(registry));
        assert!(n_public <= MAX_SUI_PUBLIC_INPUTS, errors::too_many_public_inputs());
        assert!(n_public == 2 + n_inputs + n_outputs, errors::invalid_verifying_key());
        assert!(vk_hash.length() == VK_HASH_LEN, errors::invalid_verifying_key());
        assert!(!contains_key(registry, n_inputs, n_outputs, &vk_hash), errors::invalid_verifying_key());

        let entry = VerifyingKeyEntry {
            n_inputs,
            n_outputs,
            n_public,
            vk_hash,
            prepared_vk: groth16::pvk_from_bytes(
                vk_gamma_abc_g1_bytes,
                alpha_g1_beta_g2_bytes,
                gamma_g2_neg_pc_bytes,
                delta_g2_neg_pc_bytes,
            ),
        };
        let registry_id = object::uid_to_address(&registry.id);

        events::verifying_key_registered(
            registry_id,
            n_inputs,
            n_outputs,
            n_public,
            entry.vk_hash,
        );
        vector::push_back(&mut registry.keys, entry);
    }

    public fun register_raw_key(
        cap: &AdminCap,
        pool: &Pool,
        registry: &mut VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        n_public: u8,
        vk_hash: vector<u8>,
        raw_verifying_key: vector<u8>,
    ) {
        pool::assert_admin(cap, pool);
        pool::assert_vk_registry(pool, object::id(registry));
        assert!(n_public <= MAX_SUI_PUBLIC_INPUTS, errors::too_many_public_inputs());
        assert!(n_public == 2 + n_inputs + n_outputs, errors::invalid_verifying_key());
        assert!(vk_hash.length() == VK_HASH_LEN, errors::invalid_verifying_key());
        assert!(!contains_key(registry, n_inputs, n_outputs, &vk_hash), errors::invalid_verifying_key());

        let curve = groth16::bn254();
        let prepared_vk = groth16::prepare_verifying_key(&curve, &raw_verifying_key);
        let entry = VerifyingKeyEntry {
            n_inputs,
            n_outputs,
            n_public,
            vk_hash,
            prepared_vk,
        };
        let registry_id = object::uid_to_address(&registry.id);

        events::verifying_key_registered(
            registry_id,
            n_inputs,
            n_outputs,
            n_public,
            entry.vk_hash,
        );
        vector::push_back(&mut registry.keys, entry);
    }

    public fun verify_join_split(
        registry: &VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        vk_hash: vector<u8>,
        public_inputs: vector<u8>,
        proof_points: vector<u8>,
    ): bool {
        let entry = find_key(registry, n_inputs, n_outputs, &vk_hash);
        assert!(public_inputs.length() == ((entry.n_public as u64) * 32), errors::invalid_proof());

        let curve = groth16::bn254();
        let public_inputs = groth16::public_proof_inputs_from_bytes(public_inputs);
        let proof = groth16::proof_points_from_bytes(proof_points);

        groth16::verify_groth16_proof(&curve, &entry.prepared_vk, &public_inputs, &proof)
    }

    public fun contains_key(
        registry: &VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        vk_hash: &vector<u8>,
    ): bool {
        let mut i = 0;
        let len = registry.keys.length();
        while (i < len) {
            let entry = &registry.keys[i];
            if (
                entry.n_inputs == n_inputs
                    && entry.n_outputs == n_outputs
                    && &entry.vk_hash == vk_hash
            ) {
                return true
            };
            i = i + 1;
        };
        false
    }

    fun find_key(
        registry: &VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        vk_hash: &vector<u8>,
    ): &VerifyingKeyEntry {
        let mut i = 0;
        let len = registry.keys.length();
        while (i < len) {
            let entry = &registry.keys[i];
            if (
                entry.n_inputs == n_inputs
                    && entry.n_outputs == n_outputs
                    && &entry.vk_hash == vk_hash
            ) {
                return entry
            };
            i = i + 1;
        };
        abort errors::verifying_key_not_found()
    }
}
