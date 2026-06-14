# Testing Flow

This repo uses explicit test tiers so fast deterministic checks stay separate from
Docker, Bitcoin regtest, Sui network, Ika, and proof-generation dependencies.

## Current Tiers

| Tier | Command | Purpose | External dependencies |
| --- | --- | --- | --- |
| Unit | `bun run test:unit` | Move unit tests, indexer unit tests, pure script helper tests | Sui CLI, Bun |
| Script build | `bun run test:build` | Build primary script entrypoints | Bun |
| All script build | `bun run check:scripts:all` | Build every script entrypoint | Bun |
| Local validator | `bun run test:local` | Live validator E2E smoke flow | Local Sui package publish/context |
| Bitcoin regtest | `bun run test:regtest` | Full BTC regtest + Sui flow against an already-running service | Esplora, circuit artifacts, Sui state |
| Managed Bitcoin regtest | `bun run test:regtest:managed` | Start configured compose service, run flow, stop after | Docker/Compose, circuit artifacts, Sui state |

## Refactor Boundary

Entry scripts should stay thin and orchestrate named phases. Shared logic belongs
under `scripts/test-flow` or `scripts/lib`.

Use `scripts/test-flow` for scenario-specific, testable flow pieces:

- `bitcoin-merkle.ts`: Bitcoin tx index, merkle proof, txid assertions.
- `relay-args.ts`: CLI argument parsing and validation.
- `sui-event-fields.ts`: normalized parsing for Sui event payloads.
- `proof-artifacts.ts`: Groth16 proof generation, verification, Sui export, temp cleanup.
- `regtest-config.ts`: `config/regtest.yaml` loading plus env overrides.

## Regtest Wiring

Edit `config/regtest.yaml` when your local Bitcoin regtest service uses different
ports, container names, wallet names, compose files, or joinsplit variants.
Environment variables in `.env.example` can override the same settings. The
loader still accepts legacy `regtest.config.yaml` and `UTXOPIA_REGTEST_CONFIG`.

- Use `bun run test:regtest` when regtest is already running.
- Use `bun run test:regtest:fresh` to back up current state, redeploy/init/register
  required verifying keys, and run against the already-running regtest.
- Use `bun run regtest:start` to start and prepare the configured service.
- Use `bun run regtest:stop` to stop it.
- Use `bun run test:regtest:managed` to start, run, and stop in one command.
- Use `bun run test:regtest:managed:fresh` to start, reset Sui state, run, and stop.

Run `bun scripts/regtest.ts help` to see the explicit wrapper commands. A bare
`bun scripts/regtest.ts` prints usage instead of starting the full flow.

Fresh resets keep previous state snapshots in `.tmp/state-backups` so generated
backup files do not clutter the repo root.

Use `scripts/lib` for general reusable utilities:

- `bytes.ts`: byte, hex, endian, concat, double-SHA256 helpers.
- `sui-tx.ts`: common Sui transaction object and status helpers.
- `regtest-helpers.ts`: Bitcoin regtest Docker, Esplora, and bitcoin-cli helpers.

## Maintenance Rules

- New pure helpers should get Bun tests in `scripts/test`.
- Default checks must not require Docker, testnet RPC, Ika, or proving artifacts.
- Scripts that require external state must validate inputs before side effects.
- Regtest and live flows should write their final state under a single named state key.
- If two scripts need the same byte, proof, event, or transaction helper, move it into
  `scripts/lib` or `scripts/test-flow` before adding another copy.
