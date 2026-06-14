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

### Initialization completed (matches previous program's settings)

- **BTC pool script** bound → `P2TR(32697b92…2f9908)` from the existing relayer-owned Ika
  dWallet (`dWalletId 0xe926ed3b…`, reused — no new DKG).
- **Light client** `0x34a22f07c78aee91731afde0936e2f56db2a4decc73f451401a882a111f8b473`
  (regtest, anchored at tip height 563) + `lightClientAdminCap 0x0b1f07e8…`; bound to pool.
  Bootstrapped via new `scripts/init-light-client.ts`.
- **Token registry** `0x0534d435a699f63205fa515f8c5bfaf6e015764e02ad1d42e1bc0045769e1d02`
  (empty — no Coin<T> registered, same as before), bound to pool.
- **Verifying keys**: all 15 circuits registered (same set as the previous deployment / the
  Solana set intersected with the Sui verifier cap n+m ≤ 6): `joinsplit_1x1..1x5, 2x1..2x4,
  3x1..3x3, 4x1, 4x2, 5x1`.
- Pool config: defaults from `pool::initialize(16)` (same as previous); `paused = false`.

All pool companion ids verified set on-chain.

## ⚠️ Deployment landscape mismatch (must resolve before repointing clients)

- `web/src/lib/networks.json` `sui-testnet` points at `packageId 0x719b02e476df24cea6…`
  (matches git "upgrade testnet to 0x719b02e4").
- The local `utxopia-sui-state.json` before this redeploy pointed at `0xab008e4df0b343a2…`.
- So the local state and the live web were already out of sync. Identify which package is
  the real production testnet deployment before pausing anything or repointing web.

## Remaining steps

1. ~~BTC light client bootstrap~~ — DONE (regtest tip 563).
2. ~~Register verifying keys~~ — DONE (15 circuits).
3. ~~Token registry~~ — DONE (empty, bound).
4. ~~Bind BTC pool script~~ — DONE (dWallet P2TR).
5. **Repoint clients** — update `web/src/lib/networks.json` (`sui-regtest`/`sui-testnet`) +
   any SDK config to the ids above IF you want web to drive this deployment. The regtest E2E
   scripts already use `utxopia-sui-state.json` directly, so they pick it up without a repoint.
   Do NOT repoint the public web testnet at this dev/regtest deployment.
6. **Pause/abandon the superseded package(s)** — `pool::set_paused(adminCap, pool, true)`.
   Confirm which package is production first (web currently uses `0x719b02e4…`).

---

## 2026-06-14 — superseding redeploy `0x916737cd…` (finish-forward)

The `0xaa466626…` package above was itself superseded by a newer fresh publish,
`0x916737cd…` (a brand-new package line, `UpgradeCap` version 1, type-origin == self).
`deploy.ts` had run (published + cleared shared-object refs from the state file) but
`init.ts` had **not**, leaving the deployment half-finished and `web/networks.json` in a
broken hybrid (new `packageId` paired with the old `0x91c4577d…`-origin pool). This pass
completed the on-chain initialization.

### New deployment (testnet, package `0x916737cd9b1970eb5b8b400a501ac07cd7ffa25d5da433cf9391ee4e44a2da05`)

| Object | ID |
|--------|-----|
| upgradeCap | `0x8fcc0a21b779014a086508c1b07a49a7634c589e81941c820da8d8541e763cd2` |
| adminCap | `0xa110a55b44e1ed202c0df6b1b0f11700725894ee56c8ef4bef95ac91a3a8602a` |
| pool | `0xb26294ec15a509a9f03ff1d27c39c31c421d0cfbe4ef5b6fe7d2f348bffaa8e2` |
| commitmentTree | `0x349f86a4e189f673ae295df1a2e3aef0445a21f4d8e22bbeee981620d897338c` |
| btcDepositRegistry | `0x1872bdc48edcd9eafcce04ba7fe6d10c1921db8a0ee7837d6f25a92fcb954ae0` |
| utxoSet | `0x7c330bb24d78b1ef6f4577e88740840ddd0869684ea6bc46394696d6540eb677` |
| nullifierRegistry | `0x1ba94c10d3673b6deffbb99a49c5a9c95ed2f5cddfc29d939e164cb1a3534edc` |
| redemptionQueue | `0xea7d90ce86bbf0411e58eae7c5bc728cd1d06896833ffd01accd32458d6b8bd4` |
| redemptionCap | `0x3031a5051b9b9358b52521d89a8ef9da5675fe2fc77295060097ac62004e5d34` |
| verifyingKeyRegistry | `0x0689c95e40bd13a50cbc67015c32589c4ffb58d3c93bf474c0a7c8dfce355be5` |
| tokenRegistry | `0xd717a5aa327ef23d402535f957ebbd90fb7a433ca389fbd22054f5d311dde2b3` (empty, bound) |

### Done this pass

- `init.ts` — pool, commitment tree, btc-deposit registry, utxo set, nullifier registry,
  redemption queue, verifier registry; all five companions pinned to the pool.
- `register-vkey.ts` — all **15** circuits registered (`joinsplit_1x1..1x5, 2x1..2x4,
  3x1..3x3, 4x1, 4x2, 5x1`). vkHashes are deterministic and match prior deployments.
- `init-token-registry.ts` — token registry created + bound (left **empty**, matching prior;
  `register-sui.ts` is intentionally skipped — SUI uses `depositMode: direct`).
- `_bind-pool-btc-script.ts` — `btc_pool_script` bound to
  `P2TR(32697b924eeb4c76758383f7ac60e6b87bfd57b8cb2b7a82e7caaf262f2f9908)` (relayer dWallet
  `0xe926ed3b…`, reused). Digest `6EXPKYWHgfhyP2sjsJEfqxwkjxydTuRdUUtz2Qq8ejNF`.
- `contracts/Published.toml` regenerated to `published-at`/`original-id = 0x916737cd…`.

### BTC light client — DONE (regtest)

Docker Desktop's backend VM was wedged (CLI hung); a full backend kill + relaunch cleared it.
Restarted the existing `utxopia-esplora-regtest` container (regtest tip 663) and ran
`init-light-client.ts`:

- lightClient `0xaec86662571066800080e9ca070abcf81d5e0bde40e309a40a1ac46dbfdd9a71` (regtest,
  NETWORK_REGTEST, anchored at block 663), lightClientAdminCap
  `0xf36ccc98028a8c03e3bf1d7cb9e86c1702d277f716d7f3e9d344ab56b1b934df`.
- `pool.light_client_id` bound (bindDigest `4zZhWhMAUtiayPRxy5xSxqEzqn6AaBopeS96qEbEAwoZ`).
- Verified on-chain: all six companions + `btc_pool_script` set, `paused = false`.

### Web config — DONE (now generated, not hand-edited)

`web/networks.json` (`sui-testnet` + `sui-regtest`) was repointed to the `0x916737cd`
deployment: pool + all companions + `eventsPackageId` + light client + the correct Ika
dWallet (`0xe926ed3b…`, the one the pool's `btc_pool_script` is bound to; old `0x7f0b719d…`
was stale) + derived `bitcoin.poolAddress`.

This is no longer a manual step: **`bun run sync:web-config`** regenerates those blocks from
the deploy state, and `init-light-client.ts` runs it automatically as the last deploy step.
`bun run check:web-config` fails on drift. See `docs/config-centralization-plan.md`.
