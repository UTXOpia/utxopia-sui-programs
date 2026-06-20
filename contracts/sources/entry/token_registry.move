module utxopia::token_registry {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::Clock;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::dynamic_field as df;
    use sui::poseidon;
    use std::option::{Self, Option};
    use utxopia::bound_params;
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::errors;
    use utxopia::events;
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, AdminCap, Pool, AuditorCap};
    use utxopia::public_inputs;
    use utxopia::verifier::{Self, VerifyingKeyRegistry};
    const MAX_PUBLIC_OUTPUTS: u8 = 3;
    const MAX_BPS: u16 = 10_000;
    const ANNOUNCEMENT_TYPE_DEPOSIT: u8 = 0;
    const ANNOUNCEMENT_TYPE_TRANSFER: u8 = 1;
    public struct TokenRegistry has key {
        id: UID,
        registered: u64,
        // The single pool allowed to use this registry. Bound on first use; every later
        // registry operation must come from the same pool. Prevents a second pool from
        // binding to and sharing this registry's caps, balances, and fees (audit MEDIUM #10).
        owner_pool: Option<address>,
    }
    public struct VaultKey<phantom T> has copy, drop, store {}
    public struct FeeKey<phantom T> has copy, drop, store {}
    public struct ConfigKey<phantom T> has copy, drop, store {}
    public struct TokenCfg has store {
        token_id: u256,
        decimals: u8,
        min_deposit: u64,
        max_deposit: u64,
        deposit_cap: u64,
        total_shielded: u64,
        fee_bps: u16,
        enabled: bool,
    }
    public fun initialize_registry(ctx: &mut TxContext) {
        transfer::share_object(TokenRegistry { id: object::new(ctx), registered: 0, owner_pool: option::none() });
    }
    /// Bind the registry to `pool` on first use and require the same pool every time after,
    /// enforcing a strict 1:1 pool-to-registry relationship (audit MEDIUM #10).
    fun assert_registry_owner(registry: &mut TokenRegistry, pool: &Pool) {
        let pool_id = pool::pool_id(pool);
        if (option::is_none(&registry.owner_pool)) {
            registry.owner_pool = option::some(pool_id);
        } else {
            assert!(option::contains(&registry.owner_pool, &pool_id), errors::registry_already_owned());
        };
    }
    public fun register_token<T>(
        cap: &AdminCap,
        pool: &Pool,
        registry: &mut TokenRegistry,
        metadata: &CoinMetadata<T>,
        min_deposit: u64,
        max_deposit: u64,
        deposit_cap: u64,
        fee_bps: u16,
    ) {
        pool::assert_admin(cap, pool);
        pool::assert_token_registry(pool, object::id(registry));
        assert_registry_owner(registry, pool);
        assert!(!df::exists(&registry.id, ConfigKey<T> {}), errors::token_already_registered());
        assert!(fee_bps <= MAX_BPS, errors::invalid_token_config());
        assert!(min_deposit > 0, errors::invalid_token_config());
        assert!(min_deposit <= max_deposit, errors::invalid_token_config());
        assert!(max_deposit <= deposit_cap, errors::invalid_token_config());
        let decimals = coin::get_decimals(metadata);
        register_token_inner<T>(registry, decimals, min_deposit, max_deposit, deposit_cap, fee_bps);
    }
    /// Register a `Coin<T>` when the legacy `CoinMetadata<T>` object is unavailable.
    ///
    /// Native SUI on current testnet has migrated to the newer coin registry metadata path, while
    /// the pool still stores only the token decimals needed for amount display and accounting.
    /// This entry keeps the admin allowlist model but lets governance pin the decimals directly.
    public fun register_token_with_decimals<T>(
        cap: &AdminCap,
        pool: &Pool,
        registry: &mut TokenRegistry,
        decimals: u8,
        min_deposit: u64,
        max_deposit: u64,
        deposit_cap: u64,
        fee_bps: u16,
    ) {
        pool::assert_admin(cap, pool);
        pool::assert_token_registry(pool, object::id(registry));
        assert_registry_owner(registry, pool);
        assert!(!df::exists(&registry.id, ConfigKey<T> {}), errors::token_already_registered());
        assert!(fee_bps <= MAX_BPS, errors::invalid_token_config());
        assert!(min_deposit > 0, errors::invalid_token_config());
        assert!(min_deposit <= max_deposit, errors::invalid_token_config());
        assert!(max_deposit <= deposit_cap, errors::invalid_token_config());
        register_token_inner<T>(registry, decimals, min_deposit, max_deposit, deposit_cap, fee_bps);
    }
    fun register_token_inner<T>(
        registry: &mut TokenRegistry,
        decimals: u8,
        min_deposit: u64,
        max_deposit: u64,
        deposit_cap: u64,
        fee_bps: u16,
    ) {
        let token_id = bound_params::sui_token_id<T>();
        let cfg = TokenCfg {
            token_id,
            decimals,
            min_deposit,
            max_deposit,
            deposit_cap,
            total_shielded: 0,
            fee_bps,
            enabled: true,
        };
        df::add(&mut registry.id, ConfigKey<T> {}, cfg);
        df::add(&mut registry.id, VaultKey<T> {}, balance::zero<T>());
        df::add(&mut registry.id, FeeKey<T> {}, balance::zero<T>());
        registry.registered = registry.registered + 1;
        events::token_registered(object::uid_to_address(&registry.id), token_id, decimals, fee_bps);
    }
    public fun shield<T>(
        pool: &Pool,
        registry: &mut TokenRegistry,
        tree: &mut CommitmentTree,
        npk: vector<u8>,
        ephemeral_pub: vector<u8>,
        coin: Coin<T>,
        _clock: &Clock,
        auditor_ciphertext: vector<u8>,
    ) {
        assert!(!pool::is_permissioned(pool), errors::not_permissioned());
        shield_inner<T>(pool, registry, tree, npk, ephemeral_pub, coin, auditor_ciphertext);
    }
    public fun shield_permissioned<T>(
        auditor_cap: &AuditorCap,
        pool: &Pool,
        registry: &mut TokenRegistry,
        tree: &mut CommitmentTree,
        npk: vector<u8>,
        ephemeral_pub: vector<u8>,
        coin: Coin<T>,
        _clock: &Clock,
        auditor_ciphertext: vector<u8>,
    ) {
        pool::assert_auditor(auditor_cap, pool);
        assert!(!pool::auditor_is_frozen(pool), errors::auditor_frozen());
        shield_inner<T>(pool, registry, tree, npk, ephemeral_pub, coin, auditor_ciphertext);
    }
    fun shield_inner<T>(
        pool: &Pool,
        registry: &mut TokenRegistry,
        tree: &mut CommitmentTree,
        npk: vector<u8>,
        ephemeral_pub: vector<u8>,
        coin: Coin<T>,
        auditor_ciphertext: vector<u8>,
    ) {
        pool::assert_not_paused(pool);
        pool::assert_token_registry(pool, object::id(registry));
        assert_registry_owner(registry, pool);
        pool::assert_commitment_tree(pool, object::id(tree));
        assert!(df::exists(&registry.id, ConfigKey<T> {}), errors::token_not_registered());
        let amount = coin::value(&coin);
        let (token_id, fee, net) = {
            let cfg: &TokenCfg = df::borrow(&registry.id, ConfigKey<T> {});
            assert!(cfg.enabled, errors::token_disabled());
            assert!(amount >= cfg.min_deposit && amount <= cfg.max_deposit, errors::amount_too_small());
            let fee = (((amount as u128) * (cfg.fee_bps as u128)) / 10_000) as u64;
            let net = amount - fee;
            assert!(net > 0, errors::fee_exceeds_amount());
            assert!(((cfg.total_shielded as u128) + (net as u128)) <= (cfg.deposit_cap as u128), errors::deposit_cap_exceeded());
            (cfg.token_id, fee, net)
        };
        assert!(!commitment_tree::is_full(tree), errors::tree_full());
        let npk_field = commitment_tree::field_from_be_bytes(&npk);
        let commitment_u256 = poseidon::poseidon_bn254(&vector[npk_field, token_id, (net as u256)]);
        let commitment_be = commitment_tree::field_to_be_bytes(commitment_u256);
        let pool_id = pool::pool_id(pool);
        let leaf_index = commitment_tree::insert_commitment_bytes(tree, pool_id, commitment_be);
        let mut bal = coin::into_balance(coin);
        let fee_bal = balance::split(&mut bal, fee);
        balance::join(df::borrow_mut(&mut registry.id, FeeKey<T> {}), fee_bal);
        balance::join(df::borrow_mut(&mut registry.id, VaultKey<T> {}), bal);
        let cfg: &mut TokenCfg = df::borrow_mut(&mut registry.id, ConfigKey<T> {});
        cfg.total_shielded = cfg.total_shielded + net;
        events::stealth_announced(
            pool_id,
            ANNOUNCEMENT_TYPE_DEPOSIT,
            ephemeral_pub,
            net,
            commitment_be,
            leaf_index,
            token_id,
            auditor_ciphertext,
        );
    }
    public fun unshield<T>(
        pool: &Pool,
        registry: &mut TokenRegistry,
        tree: &mut CommitmentTree,
        nullifiers: &mut NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
        n_inputs: u8,
        n_outputs: u8,
        n_public_outputs: u8,
        vk_hash: vector<u8>,
        public_inputs: vector<u8>,
        proof_points: vector<u8>,
        nullifiers_in: vector<vector<u8>>,
        commitments_out: vector<vector<u8>>,
        stealth_data: vector<vector<u8>>,
        amounts: vector<u64>,
        recipients: vector<address>,
        _clock: &Clock,
        ctx: &mut TxContext,
    ) {
        pool::assert_not_paused(pool);
        pool::assert_token_registry(pool, object::id(registry));
        assert_registry_owner(registry, pool);
        pool::assert_commitment_tree(pool, object::id(tree));
        pool::assert_nullifier_registry(pool, object::id(nullifiers));
        pool::assert_vk_registry(pool, object::id(vk_registry));
        assert!(df::exists(&registry.id, ConfigKey<T> {}), errors::token_not_registered());
        assert!(n_public_outputs > 0, errors::invalid_join_split());
        assert!(n_public_outputs <= MAX_PUBLIC_OUTPUTS, errors::invalid_join_split());
        assert!(n_outputs >= n_public_outputs, errors::invalid_join_split());
        assert!(nullifiers_in.length() == (n_inputs as u64), errors::invalid_join_split());
        assert!(commitments_out.length() == (n_outputs as u64), errors::invalid_join_split());
        assert!(amounts.length() == (n_public_outputs as u64), errors::invalid_join_split());
        assert!(recipients.length() == (n_public_outputs as u64), errors::invalid_join_split());
        let n_tree_outputs = n_outputs - n_public_outputs;
        assert!(stealth_data.length() == (n_tree_outputs as u64), errors::invalid_join_split());
        public_inputs::assert_join_split_bindings(&public_inputs, n_inputs, n_outputs, &nullifiers_in, &commitments_out);
        public_inputs::assert_at(&public_inputs, 1, &bound_params::unshield_hash(&recipients, &stealth_data));
        let (token_id, fee_bps) = {
            let cfg: &TokenCfg = df::borrow(&registry.id, ConfigKey<T> {});
            assert!(cfg.enabled, errors::token_disabled());
            (cfg.token_id, cfg.fee_bps)
        };
        let mut k = 0u64;
        while (k < (n_public_outputs as u64)) {
            let expected = public_burn_commitment(token_id, amounts[k]);
            assert!(
                *commitments_out.borrow((n_tree_outputs as u64) + k) == expected,
                errors::invalid_commitment(),
            );
            k = k + 1;
        };
        let proof_root = public_inputs::extract(&public_inputs, 0);
        // Accept the active tree's roots OR a root of a tree the pool rotated out of, so
        // notes created before a rotation stay spendable (audit CRITICAL #0).
        assert!(
            commitment_tree::is_valid_root_bytes(tree, &proof_root)
                || pool::is_historical_root(pool, &proof_root),
            errors::stale_merkle_root(),
        );
        // Reject a full tree before the expensive Groth16 verification rather than mid-insert
        // (audit MINOR #16) when this unshield mints private/tree outputs.
        if (n_tree_outputs > 0) {
            assert!(!commitment_tree::is_full(tree), errors::tree_full());
        };
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
        let mut j = 0u64;
        while (j < (n_tree_outputs as u64)) {
            assert!(!commitment_tree::is_full(tree), errors::tree_full());
            let leaf_index = commitment_tree::insert_commitment_bytes(tree, pool_id, commitments_out[j]);
            let sd = *stealth_data.borrow(j);
            events::stealth_announced(
                pool_id,
                ANNOUNCEMENT_TYPE_TRANSFER,
                sd,
                0,
                commitments_out[j],
                leaf_index,
                token_id,
                vector[],
            );
            j = j + 1;
        };
        let mut m = 0u64;
        while (m < (n_public_outputs as u64)) {
            let amount = *amounts.borrow(m);
            let recipient = *recipients.borrow(m);
            assert!(amount > 0, errors::invalid_join_split());
            let fee = (((amount as u128) * (fee_bps as u128)) / 10_000) as u64;
            let vault: &mut Balance<T> = df::borrow_mut(&mut registry.id, VaultKey<T> {});
            let mut out = balance::split(vault, amount);
            let fee_bal = balance::split(&mut out, fee);
            let fees: &mut Balance<T> = df::borrow_mut(&mut registry.id, FeeKey<T> {});
            balance::join(fees, fee_bal);
            transfer::public_transfer(coin::from_balance(out, ctx), recipient);
            let cfg: &mut TokenCfg = df::borrow_mut(&mut registry.id, ConfigKey<T> {});
            assert!(cfg.total_shielded >= amount, errors::accounting_desync());
            cfg.total_shielded = cfg.total_shielded - amount;
            m = m + 1;
        };
    }
    public fun claim_fees<T>(
        cap: &AdminCap,
        pool: &Pool,
        registry: &mut TokenRegistry,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        pool::assert_admin(cap, pool);
        pool::assert_token_registry(pool, object::id(registry));
        assert_registry_owner(registry, pool);
        assert!(df::exists(&registry.id, ConfigKey<T> {}), errors::token_not_registered());
        let token_id = token_id<T>(registry);
        let fees: &mut Balance<T> = df::borrow_mut(&mut registry.id, FeeKey<T> {});
        let amount = balance::value(fees);
        let out = balance::split(fees, amount);
        transfer::public_transfer(coin::from_balance(out, ctx), recipient);
        events::fees_claimed(object::uid_to_address(&registry.id), token_id, amount, recipient);
    }
    fun public_burn_commitment(token_id: u256, amount: u64): vector<u8> {
        let commitment = poseidon::poseidon_bn254(&vector[0u256, token_id, (amount as u256)]);
        commitment_tree::field_to_be_bytes(commitment)
    }
    public fun registered(registry: &TokenRegistry): u64 { registry.registered }
    public fun is_registered<T>(registry: &TokenRegistry): bool {
        df::exists(&registry.id, ConfigKey<T> {})
    }
    public fun token_total_shielded<T>(registry: &TokenRegistry): u64 {
        let cfg: &TokenCfg = df::borrow(&registry.id, ConfigKey<T> {});
        cfg.total_shielded
    }
    public fun vault_value<T>(registry: &TokenRegistry): u64 {
        balance::value<T>(df::borrow(&registry.id, VaultKey<T> {}))
    }
    public fun fee_value<T>(registry: &TokenRegistry): u64 {
        balance::value<T>(df::borrow(&registry.id, FeeKey<T> {}))
    }
    public fun token_id<T>(registry: &TokenRegistry): u256 {
        let cfg: &TokenCfg = df::borrow(&registry.id, ConfigKey<T> {});
        cfg.token_id
    }
    #[test_only]
    public fun test_public_burn_commitment(token_id: u256, amount: u64): vector<u8> {
        public_burn_commitment(token_id, amount)
    }
    #[test_only]
    public fun test_register_token<T>(
        registry: &mut TokenRegistry,
        decimals: u8,
        min_deposit: u64,
        max_deposit: u64,
        deposit_cap: u64,
        fee_bps: u16,
    ) {
        let token_id = bound_params::sui_token_id<T>();
        let cfg = TokenCfg {
            token_id,
            decimals,
            min_deposit,
            max_deposit,
            deposit_cap,
            total_shielded: 0,
            fee_bps,
            enabled: true,
        };
        df::add(&mut registry.id, ConfigKey<T> {}, cfg);
        df::add(&mut registry.id, VaultKey<T> {}, balance::zero<T>());
        df::add(&mut registry.id, FeeKey<T> {}, balance::zero<T>());
        registry.registered = registry.registered + 1;
    }
    #[test_only]
    public fun test_unshield_release<T>(
        registry: &mut TokenRegistry,
        n_public_outputs: u8,
        token_id: u256,
        commitments_out: vector<vector<u8>>,
        amounts: vector<u64>,
        recipients: vector<address>,
        ctx: &mut TxContext,
    ) {
        let cfg: &TokenCfg = df::borrow(&registry.id, ConfigKey<T> {});
        let fee_bps = cfg.fee_bps;
        let mut k = 0u64;
        while (k < (n_public_outputs as u64)) {
            let expected = public_burn_commitment(token_id, amounts[k]);
            assert!(*commitments_out.borrow(k) == expected, errors::invalid_commitment());
            k = k + 1;
        };
        let mut m = 0u64;
        while (m < (n_public_outputs as u64)) {
            let amount = *amounts.borrow(m);
            let recipient = *recipients.borrow(m);
            let fee = (((amount as u128) * (fee_bps as u128)) / 10_000) as u64;
            let vault: &mut Balance<T> = df::borrow_mut(&mut registry.id, VaultKey<T> {});
            let mut out = balance::split(vault, amount);
            let fee_bal = balance::split(&mut out, fee);
            let fees: &mut Balance<T> = df::borrow_mut(&mut registry.id, FeeKey<T> {});
            balance::join(fees, fee_bal);
            transfer::public_transfer(coin::from_balance(out, ctx), recipient);
            let cfg: &mut TokenCfg = df::borrow_mut(&mut registry.id, ConfigKey<T> {});
            cfg.total_shielded = cfg.total_shielded - amount;
            m = m + 1;
        };
    }
}
