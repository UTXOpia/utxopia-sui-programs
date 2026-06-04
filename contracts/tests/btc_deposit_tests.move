#[test_only]
module utxopia::btc_deposit_tests {
    use sui::test_scenario;
    use utxopia::btc_light_client;
    use utxopia::btc_deposit::{Self, BtcDepositRegistry};
    use utxopia::commitment_tree::{Self, CommitmentTree};
    use utxopia::pool::{Self, Pool};

    const SENDER: address = @0xA11CE;

    #[test]
    fun completes_verified_deposit_once() {
        let mut scenario = test_scenario::begin(SENDER);

        pool::initialize(16, test_scenario::ctx(&mut scenario));
        btc_deposit::initialize_registry(test_scenario::ctx(&mut scenario));
        commitment_tree::initialize(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);

        let empty_root_before = commitment_tree::current_root(&tree);
        assert!(empty_root_before == commitment_tree::empty_root(), 0);

        let verified_deposit = btc_light_client::new_verified_deposit(
            bytes32(1),
            0,
            25_000,
            bytes64(3),
            bytes32(4),
            bytes32(5),
            test_scenario::ctx(&mut scenario),
        );

        btc_deposit::complete_verified_deposit(
            &pool,
            &mut tree,
            &mut registry,
            verified_deposit,
        );

        assert!(btc_deposit::claimed_count(&registry) == 1, 1);
        // The real Poseidon tree advanced: one leaf, a new (non-empty) root,
        // and the prior empty root is retained in history.
        assert!(commitment_tree::next_index(&tree) == 1, 2);
        assert!(commitment_tree::current_root(&tree) != empty_root_before, 3);
        assert!(commitment_tree::is_valid_root(&tree, empty_root_before), 4);

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    #[test, expected_failure(abort_code = 15)]
    fun rejects_duplicate_deposit_outpoint() {
        let mut scenario = test_scenario::begin(SENDER);

        pool::initialize(16, test_scenario::ctx(&mut scenario));
        btc_deposit::initialize_registry(test_scenario::ctx(&mut scenario));
        commitment_tree::initialize(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, SENDER);

        let pool = test_scenario::take_shared<Pool>(&scenario);
        let mut tree = test_scenario::take_shared<CommitmentTree>(&scenario);
        let mut registry = test_scenario::take_shared<BtcDepositRegistry>(&scenario);

        let verified_deposit = btc_light_client::new_verified_deposit(
            bytes32(1),
            0,
            25_000,
            bytes64(3),
            bytes32(4),
            bytes32(5),
            test_scenario::ctx(&mut scenario),
        );
        btc_deposit::complete_verified_deposit(&pool, &mut tree, &mut registry, verified_deposit);

        let duplicate_verified_deposit = btc_light_client::new_verified_deposit(
            bytes32(1),
            0,
            25_000,
            bytes64(3),
            bytes32(8),
            bytes32(7),
            test_scenario::ctx(&mut scenario),
        );
        btc_deposit::complete_verified_deposit(&pool, &mut tree, &mut registry, duplicate_verified_deposit);

        test_scenario::return_shared(pool);
        test_scenario::return_shared(tree);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);
    }

    fun bytes32(byte: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 32) {
            vector::push_back(&mut out, byte);
            i = i + 1;
        };
        out
    }

    fun bytes64(byte: u8): vector<u8> {
        let mut out = vector[];
        let mut i = 0u64;
        while (i < 64) {
            vector::push_back(&mut out, byte);
            i = i + 1;
        };
        out
    }
}
