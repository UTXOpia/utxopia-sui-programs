# Sui Indexer Plan — symmetric to the Solana backend

Goal: a Sui indexing backend with the same shape as Solana — **chain events → DB →
web reads** — so the web app stops hammering the public fullnode with per-request
`queryEvents`, and instead reads normalized data from a service backed by a database.

## Where we are today

| Piece | Solana backend (`backend/`) | Sui indexer (`sui-programs/indexer/`) |
|-------|------------------------------|----------------------------------------|
| Ingestion | event_indexer + reconciler (PoolState/CommitmentTree PDAs) | `sui-event-source.ts` — `queryEvents` poll + cursor |
| Store | SQLite (`redemption_tracking.db`) | `SqliteSuiIndexerStore` (bun:sqlite) ✅ |
| Projections | deposit_tracker / redemption / merkle_tree | `projections.ts` (pool-state, commitments, redemption) |
| API | axum `/api/*` | Bun HTTP `/health /state /events /pool-state /commitments /redemption` |
| Web reads it? | yes (`getBackendUrl`) | **no** — web uses `lib/sui/explorer.ts` direct RPC |

So ~70% exists. The work is: (1) upgrade ingestion to a Sui-native source, (2)
normalize the API to what the web needs, (3) point the web Sui path at the indexer.

## Ingestion: Sui-native options (the decision)

JSON-RPC `queryEvents` (current) paginates over the whole event history per call and
is rate-limited on the public node. Two native upgrades:

1. **GraphQL RPC** (`https://sui-<net>.mystenlabs.com/graphql`)
   - Single query returns events + their tx + checkpoint + timestamp, cursor-paged.
   - TS-friendly, drop-in replacement for the poll loop. Far fewer round-trips than
     JSON-RPC; server-side filtering by `emittingModule`/`eventType`.
   - **Best near-term**: biggest win for least work, stays in the existing Bun service.

2. **Custom Indexer / checkpoint stream** (`sui-data-ingestion-core`)
   - Subscribe to the full checkpoint stream (remote checkpoint store or local
     fullnode), process every checkpoint's transactions+events, commit a watermark.
   - Highest throughput + exactly-once + no missed events; this is how Sui's own
     indexer works. Heavier (Rust framework or a checkpoint-file reader).
   - **Best for mainnet/scale.**

**Decision: phase it.** Keep the existing `SuiEventSource` interface (`poll(cursor)`),
add a `GraphQLEventSource` now (Phase 1), and later add a `CheckpointEventSource`
behind the same interface (Phase 3) without touching storage/projections/API.

## Plan

### Phase 1 — GraphQL ingestion + durable DB (core of the goal)
- Add `src/sui-graphql-source.ts` implementing the existing source interface, paging
  events via GraphQL filtered by `eventsPackageId` (module `0x91c4577d…`), persisting a
  `(checkpoint, txDigest, eventSeq)` cursor in SQLite (resume on restart).
- Keep `SqliteSuiIndexerStore`; ensure tables for: events (raw), commitments
  (leaf_index, commitment, root, checkpoint), nullifiers, roots history, redemption
  requests/completions, deposits (BtcDepositVerified), pool config snapshots, cursor.
- `service.ts` runs the ingest loop (GraphQL poll → upsert → advance cursor) with
  backoff; idempotent upserts keyed by `(txDigest, eventSeq)`.

### Phase 2 — Normalized API the web can consume (symmetry with Solana)
Expose endpoints mirroring what `web/lib/sui/explorer.ts` computes today, so the web
becomes a thin reader:
- `GET /api/explorer/transactions` → list (shield/transfer/unshield/withdraw) — replaces `fetchSuiExplorerTransactions`
- `GET /api/explorer/stats` → depositCount, totalCommitments, totalShielded — replaces `fetchSuiExplorerStats`
- `GET /api/tree/leaves` and `GET /api/merkle/proof?commitment=` → server-side Merkle proof (replaces client-side `fetchSuiMerkleProof`)
- `GET /api/redemption/all` and `GET /api/redemption/{id}` → from projections
- `GET /api/deposits`, `GET /api/announcements`, `GET /api/transfers` → match the names the web already calls for Solana, for a uniform shape
- `GET /api/health`, `GET /api/relayer/meta`
- Reuse existing `/state /commitments /pool-state` internally.

### Phase 3 — Point web at the indexer (events → DB → web reads)
- Add `suiIndexerUrl` to `networks.json` (per network), default to the deployed indexer.
- Refactor `web/lib/sui/explorer.ts` to fetch from `suiIndexerUrl` with a **fallback to
  direct RPC** if the indexer is unreachable (no hard dependency / graceful degrade).
- Add short-TTL caching on the web API routes regardless (defense in depth).

### Phase 4 — Ops / scale
- Dockerfile + Railway service (mirror `backend/railway.toml`), `UTXOPIA_SUI_INDEXER_DB`
  on a persistent volume, `UTXOPIA_SUI_GRAPHQL_URL` / `packageId` / `eventsPackageId` env.
- Replay/rebuild command (drop DB, re-ingest from checkpoint 0 / genesis cursor).
- (Mainnet) swap `GraphQLEventSource` → `CheckpointEventSource`.

## Symmetry summary
ingest (GraphQL→checkpoint) → SQLite → normalized `/api/*` → web reads — exactly the
Solana shape (event_indexer/reconciler → SQLite → axum `/api/*` → web reads).

## Build order
Phase 1 (ingest+DB) → Phase 2 (API) → Phase 3 (web wire + fallback) → Phase 4 (deploy).
Phases 1–2 make the indexer authoritative; Phase 3 flips the web read path; Phase 4
hardens for scale.
