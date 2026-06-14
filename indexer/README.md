# UTXOpia Sui Indexer

Ingests UTXOpia Sui package events into sqlite and serves a normalized HTTP API, so the
web app reads from a database instead of hammering the public fullnode per request.
Symmetric to the Solana backend: **events → DB → web reads**.

## Architecture

```
ingest source ─┐
  jsonrpc (default, queryEvents)        ┌─ /api/explorer/transactions
  graphql (native, fewer round-trips)   ├─ /api/explorer/stats
       │                                ├─ /pool-state /commitments /redemption
       ▼                                │
  SqliteSuiIndexerStore  ──projections──┴─ HTTP API (Bun.serve)
  (raw events + cursor)     (pool/commitments/nullifiers/redemptions)
```

Sources are pluggable behind `SuiEventSource` (`src/types.ts`); pick with
`UTXOPIA_SUI_INDEXER_SOURCE`. A checkpoint-stream source is the planned next upgrade
(see `PLAN.md`).

> Move event types keep their ORIGINAL defining package id across upgrades, so ingest
> filters by `UTXOPIA_SUI_EVENTS_PACKAGE_ID` (not the latest `packageId`).

## Run

```bash
cp .env.example .env        # fill in package/pool/events ids
bun install
UTXOPIA_SUI_INDEXER_DB=./data/sui-indexer.db bun run src/server.ts
bun test test               # unit tests
```

## API

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | liveness + packageId |
| `GET /api/explorer/transactions` | normalized shield/transfer/withdraw list (web reads this) |
| `GET /api/explorer/stats` | totalShielded / volume / depositCount / totalCommitments |
| `GET /pool-state` | paused / latestRoot / rootIndex / leafCount |
| `GET /commitments?fromLeaf=N` | commitment leaves for client-side note scan |
| `GET /redemption?id=N` | a redemption request/completion |
| `GET /state`, `GET /events` | raw cursor + event stream |

## Deploy (Railway, mirrors `backend/`)

`Dockerfile` + `railway.toml`/`railway.json` build the Bun service; mount a volume and set
`UTXOPIA_SUI_INDEXER_DB` to a path on it. Healthcheck: `/health`. After deploy, set
`sui.indexerUrl` in the web `networks.json` to this service's URL — the web explorer then
reads from the indexer and falls back to direct RPC if it's unreachable.
