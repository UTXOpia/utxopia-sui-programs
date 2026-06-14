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

### Phase 1 — generate, don't hand-edit (low risk)
- Add a `scripts/export-web-config.ts` that reads `utxopia-sui-state.json` and emits the
  `sui` + `bitcoin` (derived `poolAddress`) + `ika` blocks for a given network key, writing
  into `web/src/lib/networks.json`. Run it as the last step of every deploy/init.
- Net effect: the JSON still exists, but is **generated** — drift becomes impossible because
  nobody edits it by hand. This alone would have prevented every bug above.

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
  → `0xe926ed3b…`, derived `poolAddress`es). This plan is the follow-up to retire the
  hand-maintained file. Phases not yet started.
