# Testnet redeploy — redeem #5 fix (new package)

The redeem #5 fix removes `max_fees_sats` from `public fun redeem`, which is an
upgrade-incompatible signature change. Deployed as a **fresh package** on Sui testnet
(`deploy.ts` + `init.ts`) rather than an in-place upgrade.

## New deployment (testnet)

| Object | ID |
|--------|-----|
| packageId | `0xaa4666263bb8e7089e4ec55d7252fdd2da512d9e0fa8f48b488fdbbffa92bf0d` |
| upgradeCap | `0x9f86b039bbd38196dc2767444270696125a33cff2bdd7baf801b2f8c3ae84db2` |
| adminCap | `0xd5e772cd0265a6d2d94d048bfd1bb106dda5386e195f1b85860f52a4a4fcab5f` |
| pool | `0xb757a0d307b5a29a430bfbc4ca4b738a1699c6ebeef1963af739d5140648bac2` |
| commitmentTree | `0x6c0467bdff2da81fdf462dd88e75b61ff08d3eed2d3f558b0aea578fd42a5f48` |
| btcDepositRegistry | `0xbb17bcd99dcc7169e4166daec40ce76e871ad491d5dc86d3a269e52bea8c2d23` |
| utxoSet | `0xc9d2832169fa7b16469115ab8a08088dc780acd615d723676f5edf3bf906d7a9` |
| nullifierRegistry | `0xd8270ad9c70c5170be2ecafd2da7385b0d9214dc1a96976a3a71a05258d59b63` |
| redemptionQueue | `0x66fd259fb4925e213dfb78ba979649d3962ccfaf5a9870782ee46092ca6a330b` |
| redemptionCap | `0xd06cab2eb6cf89b9311774ea5d2fc58b50ccdb67c60ec0c22747e4d7cd478147` |
| verifyingKeyRegistry | `0x553f63bb2a5dd6d1249311a9511e57beaa01bcad4b5b0089939370bc1a5a54b2` |

Deployer/admin address: `0x0517834683ffa77da332b1f1f7a79d17e419d007f71e0fc68595704d6edda4d1`.
Local state file: `utxopia-sui-state.json` (gitignored); pre-deploy backup saved alongside.

`init.ts` bound to the pool: commitment-tree, nullifier-registry, btc-deposit-registry,
utxo-set, vk-registry.

## ⚠️ Deployment landscape mismatch (must resolve before repointing clients)

- `web/src/lib/networks.json` `sui-testnet` points at `packageId 0x719b02e476df24cea6…`
  (matches git "upgrade testnet to 0x719b02e4").
- The local `utxopia-sui-state.json` before this redeploy pointed at `0xab008e4df0b343a2…`.
- So the local state and the live web were already out of sync. Identify which package is
  the real production testnet deployment before pausing anything or repointing web.

## Remaining steps (NOT done — each blocked on an input/dependency)

1. **BTC light client bootstrap** — `btc_light_client::initialize`. The existing flow
   (`regtest-flow.ts ensureLightClientInitialized`) anchors to a running bitcoind tip
   (network byte 3 = regtest). Needs a live Bitcoin node or explicit testnet4
   genesis/checkpoint params (raw header, height, chainwork, bits, time).
2. **Register verifying keys** — `register-vkey.ts` per circuit. Artifacts exist at
   `../circuits/build/joinsplit_<n>x<m>/joinsplit_<n>x<m>.vkey.json`; the script also needs
   the Rust `../utxopia-circuits/sui-groth16-exporter` (cargo). Decide which circuit
   dimensions to register.
3. **Token registry** — `init-token-registry.ts` + `register-sui` (which Coin<T> types).
4. **Bind BTC pool script** — `_bind-pool-btc-script.ts` needs the pool's BTC taproot
   x-only pubkey (from the Ika dWallet custody key).
5. **Repoint clients** — update `web/src/lib/networks.json` `sui-testnet` (+ any SDK config)
   to the ids above. Do this only AFTER 1–4, or web will serve a half-initialized package.
6. **Pause/abandon the superseded package** — `pool::set_paused(adminCap, pool, true)`.
   Confirm which package is production first.
