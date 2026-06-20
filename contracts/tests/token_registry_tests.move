#[test_only]
module utxopia::token_registry_tests {
    use sui::coin;
    use sui::clock;
    use sui::object;
    use sui::sui::SUI as NativeSUI;
    use sui::test_scenario;
    use utxopia::bound_params;
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::nullifier::{Self, NullifierRegistry};
    use utxopia::pool::{Self, AdminCap, AuditorCap, Pool};
    use utxopia::token_registry::{Self, TokenRegistry};
    use utxopia::verifier::{Self, VerifyingKeyRegistry};

    const SENDER: address = @0xA11CE;
    const RECIPIENT: address = @0xB0B;

    // Two distinct test coin types; the type system makes `unshield<SUI>` unable to
    // name `OTHER`'s vault (cross-token isolation is compile-time).
    public struct SUI has drop {}
    public struct OTHER has drop {}

    fun bytes(n: u64, b: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0;
        while (i < n) { vector::push_back(&mut out, b); i = i + 1; };
        out
    }

    fun setup(scenario: &mut test_scenario::Scenario) {
        pool::initialize(16, test_scenario::ctx(scenario));
        commitment_tree::initialize(test_scenario::ctx(scenario));
        nullifier::initialize_registry(test_scenario::ctx(scenario));
        verifier::initialize_registry(test_scenario::ctx(scenario));
        token_registry::initialize_registry(test_scenario::ctx(scenario));
    }

    fun bind(
        scenario: &test_scenario::Scenario,
        pool: &mut Pool,
        tree: &CommitmentTree,
        nullifiers: &NullifierRegistry,
        vk_registry: &VerifyingKeyRegistry,
        registry: &TokenRegistry,
    ) {
        let admin = test_scenario::take_from_sender<AdminCap>(scenario);
        pool::set_commitment_tree_id(&admin, pool, object::id(tree));
        pool::set_nullifier_registry_id(&admin, pool, object::id(nullifiers));
        pool::set_vk_registry_id(&admin, pool, object::id(vk_registry));
        pool::set_token_registry_id(&admin, pool, object::id(registry));
        test_scenario::return_to_sender(scenario, admin);
    }

    // ---- cross-language vector lock (spec §9) ----
    // The SDK's deriveSuiTokenId / createSuiUnshieldBoundParams must reproduce these.

    #[test]
    fun sui_token_id_matches_sdk_vector() {
        let got = bound_params::test_sui_token_id<NativeSUI>();
        // poseidon(reduce_to_field(sha2_256(type_name<0x2::sui::SUI>)), 0); SDK deriveSuiTokenId must match.
        let expected = 0x0caabf1964ddaebff1485b3fe3e37bd28c9193bb2fee5c1a827fde64975b9819;
        assert!(got == expected, 0);
    }

    #[test]
    fun unshield_hash_matches_sdk_vector() {
        let got = bound_params::test_unshield_hash(
            vector[@0xA11CE, @0xB0B],
            vector[bytes(72, 0x11)],
        );
        // Length-prefixed encoding (audit #4/#51-54): count + per-item length bound into the
        // hash. Locked to the SDK's createSuiUnshieldBoundParams.
        let expected = x"25f18c980939dfacb79f4159fed02f10537abf0608d334c5d29dd9a9e3d5f3a5";
        assert!(got == expected, 0);
    }

    // ---- register_token ----

    #[test]
    fun register_token_happy_path() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        assert!(token_registry::registered(&registry) == 0, 0);
        token_registry::test_register_token<SUI>(&mut registry, 9, 100, 1_000_000, 10_000_000, 50);

        assert!(token_registry::registered(&registry) == 1, 1);
        assert!(token_registry::is_registered<SUI>(&registry), 2);
        assert!(!token_registry::is_registered<OTHER>(&registry), 3);
        assert!(token_registry::token_id<SUI>(&registry) == bound_params::test_sui_token_id<SUI>(), 4);
        assert!(token_registry::vault_value<SUI>(&registry) == 0, 5);
        assert!(token_registry::fee_value<SUI>(&registry) == 0, 6);

        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test]
    fun register_native_sui_with_explicit_decimals() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        pool::set_token_registry_id(&admin, &mut pool, object::id(&registry));

        token_registry::register_token_with_decimals<NativeSUI>(
            &admin,
            &pool,
            &mut registry,
            9,
            100_000_000,
            1_000_000_000_000,
            100_000_000_000_000,
            0,
        );

        assert!(token_registry::registered(&registry) == 1, 0);
        assert!(token_registry::is_registered<NativeSUI>(&registry), 1);
        assert!(token_registry::token_id<NativeSUI>(&registry) == bound_params::test_sui_token_id<NativeSUI>(), 2);

        test_scenario::return_to_sender(&scenario, admin);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure]
    fun register_token_rejects_duplicate() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        token_registry::test_register_token<SUI>(&mut registry, 9, 100, 1_000_000, 10_000_000, 50);
        // Duplicate ConfigKey<SUI> add aborts (dynamic-field collision).
        token_registry::test_register_token<SUI>(&mut registry, 9, 100, 1_000_000, 10_000_000, 50);

        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    // ---- shield ----

    #[test]
    fun shield_commitment_value_and_fee_and_announcement() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        // fee_bps = 100 (1%): gross 1_000_000 -> fee 10_000, net 990_000.
        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 2_000_000, 10_000_000, 100);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));

        token_registry::shield<SUI>(
            &pool,
            &mut registry,
            &mut tree,
            bytes(32, 0x07),
            bytes(33, 0x02),
            coin,
            &clk,
            vector[],
        );

        assert!(token_registry::fee_value<SUI>(&registry) == 10_000, 0);
        assert!(token_registry::vault_value<SUI>(&registry) == 990_000, 1);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == 990_000, 2);
        // total_shielded == live Balance<T> value (value-conservation invariant).
        assert!(token_registry::token_total_shielded<SUI>(&registry) == token_registry::vault_value<SUI>(&registry), 3);
        // One leaf inserted with commitment Poseidon(npk, token_id, net).
        assert!(commitment_tree::next_index(&tree) == 1, 4);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 31)]
    fun shield_rejects_below_min() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1_000, 2_000_000, 10_000_000, 0);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(500, test_scenario::ctx(&mut scenario));

        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), coin, &clk, vector[]);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 31)]
    fun shield_rejects_above_max() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 10_000, 10_000_000, 0);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(20_000, test_scenario::ctx(&mut scenario));

        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), coin, &clk, vector[]);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 47)]
    fun shield_rejects_over_deposit_cap() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        // cap 1000, net would be 2000 -> exceeds.
        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 1_000_000, 1_000, 0);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(2_000, test_scenario::ctx(&mut scenario));

        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), coin, &clk, vector[]);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 40)]
    fun shield_rejects_unregistered_token() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        // token_registry NOT bound to the pool -> assert_token_registry aborts (E_WRONG_OBJECT=40).
        let admin = test_scenario::take_from_sender<AdminCap>(&scenario);
        pool::set_commitment_tree_id(&admin, &mut pool, object::id(&tree));
        test_scenario::return_to_sender(&scenario, admin);

        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000, test_scenario::ctx(&mut scenario));
        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), coin, &clk, vector[]);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    // ---- unshield (verifier mocked) ----

    #[test]
    fun unshield_releases_to_recipient_and_accrues_fee() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        // 1% fee. Shield 1_000_000 -> net 990_000 in vault.
        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 2_000_000, 10_000_000, 100);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));
        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), coin, &clk, vector[]);

        let fee_before = token_registry::fee_value<SUI>(&registry);
        assert!(token_registry::vault_value<SUI>(&registry) == 990_000, 0);

        // Unshield 500_000: burn-commitment Poseidon(0, token_id, 500_000); fee 5_000, net 495_000.
        let token_id = token_registry::token_id<SUI>(&registry);
        let burn = token_registry::test_public_burn_commitment(token_id, 500_000);
        token_registry::test_unshield_release<SUI>(
            &mut registry,
            1,
            token_id,
            vector[burn],
            vector[500_000],
            vector[RECIPIENT],
            test_scenario::ctx(&mut scenario),
        );

        // vault released by full 500_000; fee accrued +5_000; total_shielded -= 500_000.
        assert!(token_registry::vault_value<SUI>(&registry) == 490_000, 1);
        assert!(token_registry::fee_value<SUI>(&registry) == fee_before + 5_000, 2);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == 490_000, 3);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == token_registry::vault_value<SUI>(&registry), 4);

        // Recipient received net = 495_000.
        test_scenario::next_tx(&mut scenario, RECIPIENT);
        let out = test_scenario::take_from_sender<coin::Coin<SUI>>(&scenario);
        assert!(coin::value(&out) == 495_000, 5);
        test_scenario::return_to_sender(&scenario, out);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 3)]
    fun unshield_rejects_mutated_burn_commitment() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 2_000_000, 10_000_000, 100);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));
        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), coin, &clk, vector[]);

        let token_id = token_registry::token_id<SUI>(&registry);
        // Burn commitment for 400_000 but amount claimed 500_000 -> mismatch (E_INVALID_COMMITMENT=3).
        let burn = token_registry::test_public_burn_commitment(token_id, 400_000);
        token_registry::test_unshield_release<SUI>(
            &mut registry,
            1,
            token_id,
            vector[burn],
            vector[500_000],
            vector[RECIPIENT],
            test_scenario::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    // ---- value conservation across a shield + unshield round trip ----

    #[test]
    fun total_shielded_tracks_live_balance() {
        let mut scenario = test_scenario::begin(SENDER);
        setup(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 5_000_000, 100_000_000, 0);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // Two shields, then one unshield; the invariant holds at every step.
        let c1 = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));
        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x07), bytes(33, 0x02), c1, &clk, vector[]);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == token_registry::vault_value<SUI>(&registry), 0);

        let c2 = coin::mint_for_testing<SUI>(2_500_000, test_scenario::ctx(&mut scenario));
        token_registry::shield<SUI>(&pool, &mut registry, &mut tree, bytes(32, 0x09), bytes(33, 0x02), c2, &clk, vector[]);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == 3_500_000, 1);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == token_registry::vault_value<SUI>(&registry), 2);

        let token_id = token_registry::token_id<SUI>(&registry);
        let burn = token_registry::test_public_burn_commitment(token_id, 1_500_000);
        token_registry::test_unshield_release<SUI>(
            &mut registry,
            1,
            token_id,
            vector[burn],
            vector[1_500_000],
            vector[RECIPIENT],
            test_scenario::ctx(&mut scenario),
        );
        assert!(token_registry::token_total_shielded<SUI>(&registry) == 2_000_000, 3);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == token_registry::vault_value<SUI>(&registry), 4);

        // Cross-token isolation: OTHER's vault is independent and untouched (zero).
        token_registry::test_register_token<OTHER>(&mut registry, 6, 1, 5_000_000, 100_000_000, 0);
        assert!(token_registry::vault_value<OTHER>(&registry) == 0, 5);
        assert!(token_registry::token_total_shielded<OTHER>(&registry) == 0, 6);

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    // ---- permissioned shield tests (AuditorCap model) ----

    const AUDITOR: address = @0xAD17;

    fun setup_permissioned(scenario: &mut test_scenario::Scenario) {
        pool::initialize_permissioned(16, AUDITOR, test_scenario::ctx(scenario));
        commitment_tree::initialize(test_scenario::ctx(scenario));
        nullifier::initialize_registry(test_scenario::ctx(scenario));
        verifier::initialize_registry(test_scenario::ctx(scenario));
        token_registry::initialize_registry(test_scenario::ctx(scenario));
    }

    #[test]
    fun permissioned_shield_via_auditor_succeeds() {
        let mut scenario = test_scenario::begin(SENDER);
        setup_permissioned(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 2_000_000, 10_000_000, 100);

        test_scenario::next_tx(&mut scenario, AUDITOR);
        let auditor_cap = test_scenario::take_from_sender<AuditorCap>(&scenario);

        test_scenario::next_tx(&mut scenario, SENDER);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));

        token_registry::shield_permissioned<SUI>(
            &auditor_cap,
            &pool,
            &mut registry,
            &mut tree,
            bytes(32, 0x07),
            bytes(33, 0x02),
            coin,
            &clk,
            vector[],
        );

        assert!(token_registry::fee_value<SUI>(&registry) == 10_000, 0);
        assert!(token_registry::vault_value<SUI>(&registry) == 990_000, 1);
        assert!(token_registry::token_total_shielded<SUI>(&registry) == 990_000, 2);
        assert!(commitment_tree::next_index(&tree) == 1, 3);

        test_scenario::return_to_address(AUDITOR, auditor_cap);
        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 54)]
    fun permissioned_shield_rejects_when_frozen() {
        let mut scenario = test_scenario::begin(SENDER);
        setup_permissioned(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 2_000_000, 10_000_000, 100);

        test_scenario::next_tx(&mut scenario, AUDITOR);
        let auditor_cap = test_scenario::take_from_sender<AuditorCap>(&scenario);
        pool::set_auditor_frozen(&auditor_cap, &mut pool, true);

        test_scenario::next_tx(&mut scenario, SENDER);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));

        // frozen -> auditor_frozen (54)
        token_registry::shield_permissioned<SUI>(
            &auditor_cap,
            &pool,
            &mut registry,
            &mut tree,
            bytes(32, 0x07),
            bytes(33, 0x02),
            coin,
            &clk,
            vector[],
        );

        test_scenario::return_to_sender(&scenario, auditor_cap);
        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 56)]
    fun permissioned_shield_rejects_public_entry() {
        let mut scenario = test_scenario::begin(SENDER);
        setup_permissioned(&mut scenario);
        test_scenario::next_tx(&mut scenario, SENDER);

        let mut pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let nullifiers = test_scenario::take_shared<NullifierRegistry>(&scenario);
        let vk_registry = test_scenario::take_shared<VerifyingKeyRegistry>(&scenario);
        let mut registry = test_scenario::take_shared<TokenRegistry>(&scenario);
        bind(&scenario, &mut pool, &tree, &nullifiers, &vk_registry, &registry);

        token_registry::test_register_token<SUI>(&mut registry, 9, 1, 2_000_000, 10_000_000, 100);

        test_scenario::next_tx(&mut scenario, SENDER);
        let clk = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let coin = coin::mint_for_testing<SUI>(1_000_000, test_scenario::ctx(&mut scenario));

        // permissioned pool via public shield -> not_permissioned (56)
        token_registry::shield<SUI>(
            &pool,
            &mut registry,
            &mut tree,
            bytes(32, 0x07),
            bytes(33, 0x02),
            coin,
            &clk,
            vector[],
        );

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(nullifiers);
        test_scenario::return_shared(vk_registry);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }
}
