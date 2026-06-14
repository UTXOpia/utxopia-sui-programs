# UTXOpia Sui Programs

Sui Move contracts for UTXOpia: a privacy-preserving Bitcoin bridge with SPV-checked deposits, zkBTC private transfers, and proof-checked Bitcoin redemption.

## Package

**Move package:** `utxopia_sui`

The package uses Sui shared objects and programmable transaction blocks (PTBs). There are no numeric instruction IDs like the Solana programs; callers invoke public Move functions directly.

## Commands

```bash
# Build/check TypeScript helper scripts
bun run check:scripts

# Test Move contracts
cd contracts
sui move test
```

## Structure

```text
.
|-- contracts/
|   |-- sources/
|   |   |-- entry/           # Public protocol modules and shared objects
|   |   `-- lib/             # Pure helpers, errors, and event emitters
|   `-- tests/               # Move unit tests
|-- config/                  # Local flow configuration
|-- indexer/                 # Sui event indexer and projections
|-- scripts/                 # Deploy, init, live flows, Ika helpers
|   |-- lib/                 # Reusable script utilities
|   |-- test/                # Bun unit tests for script helpers
|   `-- test-flow/           # Regtest-specific flow helpers
|-- docs/production/         # Production hardening notes
`-- poseidon-parity/         # Poseidon parity package
```

## Move Source Map

| Folder | Modules | Role |
|--------|---------|------|
| `contracts/sources/entry` | `pool`, `commitment_tree`, `nullifier`, `btc_light_client`, `btc_deposit`, `transact`, `redemption`, `token_registry`, `verifier`, `ika_policy` | Public protocol modules, shared objects, user/admin/relayer calls, and views. |
| `contracts/sources/lib` | `bitcoin`, `bound_params`, `public_inputs`, `errors`, `events` | Pure parsing/hash helpers, proof-input binding helpers, error codes, and event emitters. |

## Lifecycle

| Step | Function | Description |
|------|----------|-------------|
| 1 | `pool::initialize` | Create the shared pool and owner `AdminCap`. |
| 2 | `commitment_tree::initialize` | Create the shared Poseidon commitment tree. |
| 3 | `nullifier::initialize_registry` | Create the shared nullifier registry. |
| 4 | `btc_deposit::initialize_registry` | Create the deposit outpoint dedup registry. |
| 5 | `btc_deposit::initialize_utxo_set` | Create the pool BTC UTXO object table. |
| 6 | `verifier::initialize_registry` | Create the Groth16 verifying-key registry. |
| 7 | `btc_light_client::initialize` | Bootstrap the Bitcoin SPV light client from a trusted checkpoint. |
| 8 | `redemption::initialize_queue` | Create the redemption queue and owner `RedemptionCap`. |
| 9 | `pool::set_*_id` | Bind canonical companion object IDs to the pool. |
| 10 | `verifier::register_*_key` | Register JoinSplit verifying keys. |
| 11 | `btc_light_client::submit_headers` | Submit Bitcoin headers and update canonical chain state. |
| 12 | `btc_light_client::verify_tx_inclusion` | Produce a same-PTB `VerifiedInclusion` for a Bitcoin tx. |
| 13 | `btc_deposit::complete_deposit` | Consume inclusion proof, verify OP_RETURN and pool output, insert commitment, record UTXO. |
| 14 | `transact::transact` | Verify JoinSplit proof, spend nullifiers, insert private output commitments. |
| 15 | `redemption::redeem` | Verify JoinSplit proof and enqueue BTC redemption requests. |
| 16 | `redemption::mark_processing` | Reserve selected pool UTXOs for a redemption. |
| 17 | `ika_policy::approve_signing` | Create policy-bound, single-use Ika signing approval. |
| 18 | `ika_policy::consume_approval` | Mark a signing approval as used in the signing PTB. |
| 19 | `redemption::complete_redemption` | Consume inclusion proof for payout tx, remove spent UTXOs, add change UTXO, close request. |

## Network IDs

| ID | Network | Status |
|----|---------|--------|
| `0` | Bitcoin mainnet | Supported by `btc_light_client`. |
| `1` | Bitcoin testnet3 | Reserved, not accepted by `btc_light_client::initialize`. |
| `2` | Bitcoin testnet4 | Supported, including testnet4 difficulty behavior. |
| `3` | Bitcoin regtest | Supported, PoW/difficulty checks bypassed for local testing. |

## Public Functions

This section lists externally callable `public fun` functions in `contracts/sources`. It intentionally omits `public(package)` internals and `#[test_only]` helpers.

### `pool`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize(tree_depth, ctx)` | Init | Creates a shared `Pool` and transfers the bound `AdminCap` to the sender. |
| `set_paused(cap, pool, paused)` | Admin | Pause or unpause pool operations. |
| `propose_deposit_config_update(...)` | Admin | Propose min/max deposit and fee changes behind the 48-hour timelock. |
| `execute_deposit_config_update(pool, clock)` | Admin/timelock | Apply a pending deposit config update once the timelock has elapsed. |
| `cancel_deposit_config_update(cap, pool)` | Admin | Cancel the pending deposit config update. |
| `set_commitment_tree_id(cap, pool, id)` | Admin bind | Set the canonical `CommitmentTree` object ID once. |
| `set_nullifier_registry_id(cap, pool, id)` | Admin bind | Set the canonical `NullifierRegistry` object ID once. |
| `set_btc_deposit_registry_id(cap, pool, id)` | Admin bind | Set the canonical `BtcDepositRegistry` object ID once. |
| `set_utxo_set_id(cap, pool, id)` | Admin bind | Set the canonical `UtxoSet` object ID once. |
| `set_vk_registry_id(cap, pool, id)` | Admin bind | Set the canonical `VerifyingKeyRegistry` object ID once. |
| `set_light_client_id(cap, pool, id)` | Admin bind | Set the canonical Bitcoin `LightClient` object ID once. |
| `set_btc_pool_script(cap, pool, script)` | Admin bind | Set the pool Bitcoin scriptPubKey once. |
| `assert_not_paused(pool)` | Guard | Abort if the pool is paused. |
| `tree_depth(pool)` | View | Return configured tree depth. |
| `paused(pool)` | View | Return pool pause state. |
| `min_deposit_sats(pool)` | View | Return minimum BTC deposit. |
| `max_deposit_sats(pool)` | View | Return maximum BTC deposit. |
| `deposit_fee_bps(pool)` | View | Return protocol deposit fee in basis points. |
| `service_fee_sats(pool)` | View | Return fixed service fee. |
| `pending_execute_after_ms(pool)` | View | Return pending config execution timestamp, if any. |
| `btc_token_id(pool)` | View | Return zkBTC token identifier used in commitments. |
| `deposit_count(pool)` | View | Return completed deposit count. |
| `total_shielded(pool)` | View | Return total shielded sats accounting value. |
| `total_utxo_sats(pool)` | View | Return total recorded pool UTXO sats accounting value. |

### `btc_light_client`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize(...)` | Init | Create a shared Bitcoin light client from a trusted checkpoint. |
| `set_paused(cap, lc, paused)` | Admin | Pause or unpause header submission and inclusion checks. |
| `submit_headers(lc, raw_headers, clock)` | SPV | Submit up to 10 consecutive Bitcoin headers and update canonical chainwork. |
| `confirmations(lc, block_hash)` | View | Return confirmations for a canonical block hash, or `0`. |
| `verify_tx_inclusion(...)` | SPV | Verify a Bitcoin tx merkle proof and return a hot-potato `VerifiedInclusion`. |
| `tip_hash(lc)` | View | Return canonical tip hash. |
| `tip_height(lc)` | View | Return canonical tip height. |
| `total_chainwork(lc)` | View | Return cumulative chainwork. |
| `finalized_height(lc)` | View | Return finalized height based on required confirmations. |
| `network(lc)` | View | Return configured Bitcoin network ID. |
| `is_paused(lc)` | View | Return light-client pause state. |
| `header_count(lc)` | View | Return stored header count. |
| `required_confirmations(lc)` | View | Return required confirmations for this network. |

### `btc_deposit`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize_registry(ctx)` | Init | Create the shared BTC deposit outpoint dedup registry. |
| `initialize_utxo_set(ctx)` | Init | Create the shared pool UTXO object table. |
| `complete_deposit(...)` | Deposit | Consume `VerifiedInclusion`, verify raw Bitcoin tx data and OP_RETURN, insert a note commitment, and record the pool UTXO. |
| `claimed_count(registry)` | View | Return number of claimed deposit outpoints. |
| `is_claimed(registry, txid, vout)` | View | Return whether a deposit outpoint was already claimed. |
| `contains_utxo(utxo_set, txid, vout)` | View | Return whether a pool UTXO is recorded. |

### `transact`

| Function | Kind | Description |
|----------|------|-------------|
| `transact(...)` | Transfer | Verify a JoinSplit proof, reject stale roots, record nullifiers, and insert output commitments. |

### `redemption`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize_queue(ctx)` | Init | Create the shared redemption queue and transfer the bound `RedemptionCap` to the sender. |
| `redeem(...)` | Withdraw request | Verify a JoinSplit proof with public BTC redemption outputs and enqueue redemption requests. |
| `mark_processing(...)` | UTXO selection | Reserve selected pool UTXOs and bind them to a redemption request. |
| `complete_redemption(...)` | Withdraw settlement | Consume payout tx inclusion proof, verify selected inputs and destination output, remove spent UTXOs, record change UTXO, and delete the request. |

### `ika_policy`

| Function | Kind | Description |
|----------|------|-------------|
| `check_redemption_signing(pool, amount_sats, miner_fee_sats)` | Policy | Enforce pool pause state plus max redemption amount and miner fee caps. |
| `approve_signing(...)` | Policy | Create a single-use, redemption-bound Ika signing approval for one sighash. |
| `consume_approval(cap, pool, queue, approval, ctx)` | Policy | Mark a fresh approval as used after re-checking it is still bound and pending. |
| `approval_sighash(approval)` | View | Return approved sighash. |
| `approval_redemption_id(approval)` | View | Return bound redemption ID. |
| `approval_used(approval)` | View | Return whether approval has been consumed. |
| `approval_btc_script(approval)` | View | Return bound BTC destination script. |
| `approval_amount_sats(approval)` | View | Return approved redemption amount. |
| `approval_dwallet_cap_id(approval)` | View | Return bound dWallet capability ID. |

### `verifier`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize_registry(ctx)` | Init | Create the shared Groth16 verifying-key registry. |
| `register_prepared_key(...)` | Admin | Register a prepared BN254 Groth16 verifying key. |
| `register_raw_key(...)` | Admin | Prepare and register a raw BN254 Groth16 verifying key. |
| `verify_join_split(...)` | Verify | Verify a JoinSplit Groth16 proof for a registered key. |
| `contains_key(registry, n_inputs, n_outputs, vk_hash)` | View | Return whether the registry contains a key. |

### `commitment_tree`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize(ctx)` | Init | Create a shared empty Poseidon Merkle tree. |
| `is_valid_root(tree, root)` | View | Return whether a field root is current or in recent history. |
| `is_valid_root_bytes(tree, root_be)` | View | Return whether a 32-byte root is valid and canonical field data. |
| `current_root(tree)` | View | Return current root as `u256`. |
| `current_root_bytes(tree)` | View | Return current root as 32-byte big-endian data. |
| `next_index(tree)` | View | Return next leaf index. |
| `is_full(tree)` | View | Return whether the tree has reached capacity. |
| `id(tree)` | View | Return tree object address. |
| `empty_root()` | View | Return the empty-tree root. |
| `field_to_be_bytes(x)` | Utility | Encode a field element as 32-byte big-endian data. |

### `nullifier`

| Function | Kind | Description |
|----------|------|-------------|
| `initialize_registry(ctx)` | Init | Create the shared nullifier registry. |
| `contains(registry, nullifier)` | View | Return whether a nullifier has already been spent. |

### `bitcoin`

| Function | Kind | Description |
|----------|------|-------------|
| `output_value(output)` | View | Return parsed Bitcoin output value. |
| `output_script(output)` | View | Return parsed Bitcoin output scriptPubKey. |
| `input_prev_txid(input)` | View | Return parsed input previous txid. |
| `input_prev_vout(input)` | View | Return parsed input previous vout. |

### `events`

`events` exposes event structs for indexers and uses package-only emit helpers. Event structs:

| Event | Description |
|-------|-------------|
| `PoolCreated` | Pool initialized. |
| `PoolPaused` | Pool pause state changed. |
| `CommitmentInserted` | New commitment inserted into the Merkle tree. |
| `BtcDepositVerified` | BTC deposit verified and note commitment created. |
| `MerkleRootUpdated` | Commitment tree root changed. |
| `NullifierSpent` | Nullifier recorded as spent. |
| `RedemptionRequested` | BTC redemption request created. |
| `RedemptionCompleted` | BTC redemption settled by SPV-verified payout tx. |
| `IkaSigningApproved` | Ika signing approval created. |
| `VerifyingKeyRegistered` | JoinSplit verifying key registered. |
| `JoinSplitVerified` | JoinSplit proof verified. |
| `HeadersSubmitted` | Bitcoin headers accepted by the light client. |

### `errors`

| Function | Kind | Description |
|----------|------|-------------|
| `pool_paused()` | Error code | Pool operation attempted while paused. |
| `invalid_tree_depth()` | Error code | Invalid Merkle tree depth. |
| `invalid_commitment()` | Error code | Invalid private note commitment. |
| `nullifier_spent()` | Error code | Nullifier was already spent. |
| `redemption_completed()` | Error code | Redemption request was already completed. |
| `invalid_redemption()` | Error code | Malformed or mismatched redemption data. |
| `policy_rejected()` | Error code | Pool policy rejected the operation. |
| `invalid_verifying_key()` | Error code | Groth16 verifying key data is invalid. |
| `verifying_key_not_found()` | Error code | Requested verifying key is not registered. |
| `invalid_proof()` | Error code | Groth16 proof payload is invalid. |
| `too_many_public_inputs()` | Error code | Proof public-input count exceeds the accepted bound. |
| `verification_failed()` | Error code | Proof verification failed. |
| `invalid_join_split()` | Error code | JoinSplit public inputs or proof binding are invalid. |
| `invalid_btc_deposit()` | Error code | Bitcoin deposit transaction or OP_RETURN is invalid. |
| `btc_deposit_already_claimed()` | Error code | Bitcoin deposit outpoint was already claimed. |
| `stale_merkle_root()` | Error code | JoinSplit root is not current or recently accepted. |
| `tree_full()` | Error code | Commitment tree has reached capacity. |
| `commitment_out_of_field()` | Error code | Commitment bytes are not canonical BN254 field data. |
| `header_prev_mismatch()` | Error code | Bitcoin header does not connect to known previous hash. |
| `pow_not_met()` | Error code | Bitcoin header proof-of-work is below target. |
| `bad_bits()` | Error code | Bitcoin compact target bits are invalid. |
| `unknown_block()` | Error code | Referenced Bitcoin block is unknown. |
| `not_canonical()` | Error code | Referenced Bitcoin block is not on the canonical chain. |
| `insufficient_conf()` | Error code | Bitcoin transaction does not have enough confirmations. |
| `bad_merkle_proof()` | Error code | Bitcoin merkle proof does not prove inclusion. |
| `lc_paused()` | Error code | Light-client operation attempted while paused. |
| `bad_header_len()` | Error code | Bitcoin header batch length is invalid. |
| `batch_too_large()` | Error code | Bitcoin header batch exceeds the accepted bound. |
| `tx_truncated()` | Error code | Raw Bitcoin transaction is truncated. |
| `invalid_raw_tx()` | Error code | Raw Bitcoin transaction encoding is invalid. |
| `amount_too_small()` | Error code | Amount is below configured minimum. |
| `amount_too_large()` | Error code | Amount exceeds configured maximum. |
| `fee_exceeds_amount()` | Error code | Fee is greater than the operation amount. |
| `invalid_stealth_op_return()` | Error code | OP_RETURN stealth payload is invalid. |
| `utxo_exists()` | Error code | Pool UTXO already exists. |
| `deposit_linkage_failed()` | Error code | Deposit output and note commitment linkage failed. |
| `approval_used()` | Error code | Ika signing approval was already consumed. |
| `approval_expired()` | Error code | Ika signing approval expired. |
| `wrong_cap()` | Error code | Capability object is not bound to the target object. |
| `wrong_object()` | Error code | Supplied shared object does not match the pool binding. |
| `already_bound()` | Error code | One-time pool binding is already set. |
| `no_pending_proposal()` | Error code | No timelocked config proposal is pending. |
| `timelock_not_elapsed()` | Error code | Timelocked config proposal is not executable yet. |

## Object Model

| Object | Owner | Purpose |
|--------|-------|---------|
| `Pool` | Shared | Protocol policy, canonical object bindings, and accounting. |
| `AdminCap` | Sender-owned | Authority over exactly one pool. |
| `CommitmentTree` | Shared | Poseidon Merkle tree and recent root history. |
| `NullifierRegistry` | Shared | Spent nullifier registry. |
| `BtcDepositRegistry` | Shared | BTC deposit outpoint dedup table. |
| `UtxoSet` | Shared | Pool BTC UTXO object table. |
| `LightClient` | Shared | Bitcoin header chain and canonical chainwork state. |
| `LightClientAdminCap` | Sender-owned | Authority over exactly one light client. |
| `VerifyingKeyRegistry` | Shared | JoinSplit verifying keys. |
| `RedemptionQueue` | Shared | Pending BTC redemption requests. |
| `RedemptionCap` | Sender-owned | Authority over exactly one redemption queue. |
| `SigningApproval` | Shared | Single-use Ika signing approval object. |

## Security Notes

- Deposits require a same-PTB `VerifiedInclusion` from `btc_light_client::verify_tx_inclusion`.
- Deposit replay is prevented by the immutable Bitcoin deposit outpoint `(txid, vout)`.
- The pool pins canonical companion object IDs once, so callers cannot substitute fresh registries or trees.
- Transfers and redemptions verify registered JoinSplit Groth16 proofs before spending nullifiers.
- Redemptions reserve concrete pool UTXOs before signing and remove them only after the BTC payout tx is SPV-verified.
- Ika signing approvals are single-use and bound to a pending redemption, sighash, amount, destination script, and dWallet cap.
- Mainnet and testnet4 light-client paths enforce PoW and difficulty; regtest intentionally bypasses those checks for local testing.
