# Plan: centralize deployment config (stop web defining its own values)

## Why

Every config bug hit during the `0x916737cd` finish-forward had the same root cause:
**`web/src/lib/networks.json` is a hand-maintained duplicate of values the deploy/init
pipeline already writes to `utxopia-sui-state.json`.** Two sources of truth kept in sync by
hand → guaranteed drift. Observed drift in this episode:

- `packageId` repointed to the new package but `pool` left at the old `0x91c4577d` line.
- `lightClient` still pointing at an old-package object.
- `ika.dWalletId` = `0x7f0b719d…` (stale) while the pool was bound to `0xe926ed3b…`.
- `bitcoin.poolAddress` empty, even though it's fully derivable from the bound dWallet key.

## Principles

1. **One origin for deployment identity.** Package id, shared-object ids, caps, dWallet id —
   all originate from the deploy/init pipeline (`utxopia-sui-state.json`), never hand-typed
   into web.
2. **Derive, don't store, anything computable.** `poolAddress = P2TR(dWallet xonly, network)`.
   It should be computed, not persisted. Same for values readable from the pool object.
3. **Separate identity from endpoints.** Deployment *identity* (ids) and per-environment
   *endpoints/secrets* (RPC URLs, explorer URLs) have different lifecycles — keep them in
   separate layers so an endpoint edit can't disturb a deployment id and vice-versa.

## Approach (incremental)

### Phase 1 — generate, don't hand-edit (low risk) — DONE 2026-06-14
- `scripts/export-web-config.ts` reads `utxopia-sui-state.json` and projects deployment
  identity onto `web/src/lib/networks.json`: `packageId`, `eventsPackageId`, pool + all
  companion object refs, `redemptionCap`, bound `ika.dWalletId`/`dWalletCapObjectId`, and vk
  hashes — and **derives** `bitcoin.poolAddress` = `P2TR(bound dWallet x-only key)` via the
  dependency-free encoder in `scripts/lib/bech32m.ts`. Endpoints (rpcUrl/explorerUrl/Ika
  infra ids) are left untouched.
- Pure mapping in `scripts/test-flow/web-config.ts`; covered by
  `scripts/test/{bech32m,web-config}.test.ts`.
- Commands: `bun run sync:web-config` (write), `bun run check:web-config` (CI/local guard,
  exit 1 on drift). `init-light-client.ts` (the last deploy step) calls the sync
  automatically (non-fatal if the web checkout is absent).
- Net effect: the JSON is now **generated**, not hand-edited — the drift class is closed.
- Caveat: `--check` compares against the gitignored deploy state, so it's a *local/pre-commit*
  guard, not a hosted-CI check (CI has no deploy state). A hosted check needs Phase 2/3.

### Phase 2 — SDK owns the canonical config (medium)
- Move the generated config into the SDK (`sdk/.../config` or `sdk-sui`) and have web import
  `getNetworkConfig('sui-testnet')` instead of reading its own JSON. Backend/scripts import
  the same accessor. Web stops defining its own values entirely.
- `poolAddress` becomes a derived helper (`poolAddressFor(network)`), not a stored field.

### Phase 3 (optional) — on-chain source of truth (higher)
- Publish a small registry object on-chain that names the canonical shared-object ids; SDK
  resolves ids at runtime by reading it. Eliminates the build-time-snapshot problem: web
  survives a redeploy with no rebuild. Heavier; only worth it if redeploys are frequent.

## Caveat

A generated/SDK-baked config (Phases 1–2) is a build-time snapshot — a redeploy still needs a
web rebuild to pick up new ids. Phase 3 removes that, at the cost of an on-chain read on every
config resolve. Pick based on redeploy cadence.

## Status

- 2026-06-14: tactical patch applied to `networks.json` (`sui-testnet`/`sui-regtest` dWallet
  → `0xe926ed3b…`, derived `poolAddress`es).
- 2026-06-14: **Phase 1 done** — `export-web-config.ts` + bech32m derivation + tests; web
  config is now generated from deploy state. `bun run check:web-config` confirms the
  committed `networks.json` matches the deploy state. Phases 2–3 not started.
