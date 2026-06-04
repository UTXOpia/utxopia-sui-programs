# 06 — Sui Indexer: Persistence, Reliable Event Sync, and Note Scanning

Status: implementation-ready spec
Target: trustless mainnet parity with the Solana implementation (the indexer is a *convenience/availability* layer only — it MUST NOT be trusted for fund safety; all values it serves are independently verifiable against on-chain commitments).
Module owner: `chains/sui/indexer`

---

## 1. Goal & what this replaces

### 1.1 Goal

Turn the Sui indexer from an in-memory PoC into a production service that:

1. Persists all UTXOpia Sui Move events durably with a **monotonic, restart-safe cursor** (`(txDigest, eventSeq)` + checkpoint).
2. Performs **reliable event sync** from the Sui RPC `queryEvents` API with gap-detection, idempotent upserts, and reorg tolerance (Sui has no L1 reorgs post-checkpoint-finality, but RPC node failover / pruning / replays require defensive handling).
3. Implements **note scanning** server-side: reconstructs shielded notes from `BtcDepositVerified` (deposit) and a NEW `StealthAnnounced` (transfer) event via viewing-key/npk matching, mirroring the SDK's `scanUnifiedNotes` (`sdk/src/stealth.ts:829`).
4. Exposes the **query APIs the SDK needs**: `getPoolState`, `latestMerkleRoot`, `getNotes`, `redemption status`, and the legacy `/api/announcements` contract the `@utxopia/sdk` `AnnouncementClient` already consumes.

### 1.2 What it replaces (cite file:line)

| Stub | Location | Replacement |
|------|----------|-------------|
| `InMemorySuiIndexerStore` — events in a JS array, lost on restart | `chains/sui/indexer/src/storage.ts:11-39` | SQLite-backed `SqliteSuiIndexerStore` (already partially present at `storage.ts:41-175`) hardened + extended to the full `SuiIndexerStore` interface below |
| `getEventsAfter` does a full table scan + `findIndex` in JS | `chains/sui/indexer/src/storage.ts:138-174` | Indexed, seek-paginated SQL query on a monotonic `seq` column |
| `SuiIndexerStore` interface only has `getState/saveState/saveEvents/getEventsAfter` — no note/pool/redemption queries | `chains/sui/indexer/src/storage.ts:4-9` | Extended interface (§3) with note/commitment/nullifier/redemption/root reads |
| `syncOnce` does ONE page per call, never drains `hasNextPage`, persists cursor only when `nextCursor` is present (drops the final partial page's progress) | `chains/sui/indexer/src/service.ts:11-24` | `drain()` loop that paginates to tip, persists cursor per page, derived-state projection per event |
| `SuiBitcoinNode` — thin wrapper, no deposit→event correlation | `chains/sui/indexer/src/bitcoin-node.ts` | Out of scope here (BTC light-client relayer is spec 0x; this module only consumes already-verified on-chain events). Leave as-is. |
| API serves only `/health`, `/state`, `/events` (raw event dump) | `chains/sui/indexer/src/api.ts:7-25` | Full HTTP contract (§ API) |
| `UTXOpiaSuiAdapter.getNotes` throws "requires the Sui indexer API implementation"; `getPoolState`/`getLatestMerkleRoot` return hardcoded empties | `packages/sdk-sui/src/sui-adapter.ts:48-72` | Adapter calls this indexer's HTTP API |

### 1.3 Hard dependency surfaced by this spec (Move-side gap)

Note scanning for **transfers** is impossible with the current event set. `transact.move` (`chains/sui/contracts/sources/transact.move:9-51`) emits only `CommitmentInserted` and `JoinSplitVerified` — neither carries the `ephemeralPub` or `encryptedAmount` a viewing key needs. Only the **deposit** path (`BtcDepositVerified`, `chains/sui/contracts/sources/events.move:21-30`) carries `ephemeral_pubkey` + `npk` + plaintext `amount_sats`.

**This spec REQUIRES a new Move event `StealthAnnounced`** (defined in §2.5) emitted by `transact` for every output commitment, carrying `(announcement_type, ephemeral_pub, encrypted_amount, commitment, leaf_index)`. This mirrors Solana's `sol_log_data` stealth announcement (CLAUDE.md "Non-Interactive Deposit": `type=0` deposit plaintext, `type=1` transfer XOR-encrypted). Without it, the indexer can only scan deposits, not received transfers. Flag this as a cross-module dependency on the `transact`/`events` Move spec.

---

## 2. Data model (storage schema)

### 2.1 Database choice: **SQLite (via `bun:sqlite`)**, with a Postgres-compatible DDL abstraction

Justification:

- The repo already ships `bun:sqlite` in `storage.ts:2` and the backend deposit tracker uses SQLite (`backend/src/deposit_tracker/sqlite_db.rs`). Zero new infra.
- Write volume is low: one writer (the sync loop), append-mostly. UTXOpia commitment tree is depth-16 → max 65,536 leaves ever. Even at mainnet a single pool's lifetime event count fits comfortably in SQLite with WAL mode.
- Reads (`getNotes`, `latestMerkleRoot`) are point/range lookups on indexed columns — SQLite handles these in microseconds.
- **Single-writer** model matches the indexer's single sync loop; no multi-writer contention that would justify Postgres.

Postgres is offered as a **drop-in alternative** behind the same `SuiIndexerStore` interface for operators who want read replicas / HA. The DDL below is written in the common subset; `INTEGER PRIMARY KEY AUTOINCREMENT` (SQLite) maps to `BIGSERIAL` (PG), `text` stays `text`, blobs are stored as **lowercase hex `text`** (NOT `BLOB`) so the same column type works on both engines and serializes directly to JSON for the API. Pick SQLite for the default deployment; document the PG switch as `UTXOPIA_SUI_INDEXER_DRIVER=postgres`.

WAL pragmas to set on open:
```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
```

### 2.2 Conventions

- All 32-byte field elements / hashes / commitments / nullifiers stored as **64-char lowercase hex** (no `0x` prefix) in `text` columns. This matches the SDK's `parseAnnouncementsFromHex` (`sdk/src/stealth.ts:1092`) which expects hex strings.
- `leaf_index`, `root_index`, `redemption_id`, `seq` are `INTEGER` (i64). Sui `u64` amounts that can exceed JS safe-int are stored as `text` decimal strings (e.g. `amount_sats`).
- `event_seq` from Sui RPC is a **stringified u64**; store as `text` and sort by the numeric `seq` surrogate (below), never lexicographically.
- One indexer process serves exactly one `(package_id, pool_object_id)`. Every table carries `package_id` to allow a shared DB across networks (testnet/mainnet) if desired; all queries filter on it.

### 2.3 Tables

```sql
-- ── Cursor / sync state ───────────────────────────────────────────────
create table if not exists sync_state (
  package_id        text primary key,
  pool_object_id    text not null,
  last_tx_digest    text,            -- Sui RPC cursor: txDigest
  last_event_seq    text,            -- Sui RPC cursor: eventSeq (stringified u64)
  last_checkpoint   text,            -- highest checkpoint observed (string u64)
  last_seq          integer not null default 0,  -- monotonic surrogate (see raw_events.seq)
  events_ingested   integer not null default 0,
  updated_at        integer not null  -- epoch ms
);

-- ── Raw event log (append-only, source of truth for replay) ───────────
create table if not exists raw_events (
  seq               integer primary key autoincrement,  -- monotonic ingest order
  package_id        text not null,
  pool_object_id    text not null,
  event_type        text not null,    -- e.g. 'CommitmentInserted'
  tx_digest         text not null,
  event_seq         text not null,    -- Sui per-tx event sequence
  checkpoint        text,             -- Sui checkpoint number (string u64)
  timestamp_ms      integer,          -- from event.timestampMs when available
  payload_json      text not null,    -- normalized parsedJson
  ingested_at       integer not null,
  unique (tx_digest, event_seq)        -- idempotency key (Sui event id is globally unique)
);
create index if not exists idx_raw_events_pkg_seq   on raw_events (package_id, seq);
create index if not exists idx_raw_events_type       on raw_events (package_id, event_type, seq);
create index if not exists idx_raw_events_checkpoint on raw_events (package_id, checkpoint);

-- ── Projected: commitments / notes (one row per inserted leaf) ────────
create table if not exists commitments (
  package_id        text not null,
  pool_object_id    text not null,
  leaf_index        integer not null,
  commitment        text not null,    -- 64-hex Poseidon(npk, token, amount)
  announcement_type integer,          -- 0 deposit, 1 transfer, null if unknown
  ephemeral_pub     text,             -- 64-hex Ed25519 ephemeral pubkey (32 bytes)
  encrypted_amount  text,             -- 16-hex (8 bytes): plaintext LE if type=0, XOR if type=1
  token_id          text,             -- decimal/hex token id (zkBTC default)
  deposit_txid      text,             -- 64-hex, deposits only
  deposit_vout      integer,          -- deposits only
  amount_sats       text,             -- decimal string; plaintext for deposits only
  source_tx_digest  text not null,
  checkpoint        text,
  timestamp_ms      integer,
  seq               integer not null,  -- raw_events.seq that produced this row
  primary key (package_id, leaf_index)
);
create index if not exists idx_commitments_pkg_seq    on commitments (package_id, seq);
create index if not exists idx_commitments_commitment on commitments (package_id, commitment);
create index if not exists idx_commitments_type       on commitments (package_id, announcement_type, leaf_index);

-- ── Projected: merkle roots (history, for membership/sync windows) ────
create table if not exists merkle_roots (
  package_id        text not null,
  pool_object_id    text not null,
  root_index        integer not null,
  root              text not null,    -- 64-hex
  source_tx_digest  text not null,
  checkpoint        text,
  timestamp_ms      integer,
  seq               integer not null,
  primary key (package_id, root_index)
);
create index if not exists idx_roots_pkg_seq on merkle_roots (package_id, seq);
create index if not exists idx_roots_root    on merkle_roots (package_id, root);

-- ── Projected: nullifiers (double-spend detection / wallet filtering) ─
create table if not exists nullifiers (
  package_id        text not null,
  nullifier         text not null,    -- 64-hex
  source_tx_digest  text not null,
  checkpoint        text,
  seq               integer not null,
  primary key (package_id, nullifier)
);
create index if not exists idx_nullifiers_pkg_seq on nullifiers (package_id, seq);

-- ── Projected: pool state (single row per pool) ───────────────────────
create table if not exists pool_state (
  package_id        text not null,
  pool_object_id    text primary key,
  tree_depth        integer not null,
  paused            integer not null default 0,
  latest_root       text,             -- 64-hex
  latest_root_index integer not null default 0,
  next_leaf_index   integer not null default 0,
  version           integer,
  updated_seq       integer not null,
  updated_at        integer not null
);

-- ── Projected: redemptions (status tracking) ──────────────────────────
create table if not exists redemptions (
  package_id        text not null,
  pool_object_id    text not null,
  redemption_id     integer not null,
  status            text not null,    -- 'requested' | 'approved' | 'completed'
  btc_address_hash  text,             -- 64-hex (or shorter) from RedemptionRequested
  amount_sats       text,             -- decimal string
  max_fee_sats      text,             -- decimal string
  sighash           text,             -- 64-hex, set on IkaSigningApproved
  btc_txid          text,             -- 64-hex, set on RedemptionCompleted
  requested_seq     integer,
  approved_seq      integer,
  completed_seq     integer,
  updated_at        integer not null,
  primary key (package_id, redemption_id)
);
create index if not exists idx_redemptions_status on redemptions (package_id, status);
```

### 2.4 Why a `seq` surrogate (not the Sui cursor) for ordering

Sui's `(txDigest, eventSeq)` cursor is opaque and NOT globally monotonic-sortable as text. The `raw_events.seq` autoincrement is the **ingest-order monotonic key** used for: seek pagination (`getNotes fromCursor`), projection idempotency, and "events after X" queries. The Sui cursor is persisted only to resume `queryEvents`. We never sort wallet results by the Sui cursor.

### 2.5 Required Move event (cross-module dependency)

Add to `chains/sui/contracts/sources/events.move` and emit from `transact` per output commitment (and optionally re-emit for deposits so one event type covers both, but deposits already carry the data in `BtcDepositVerified`):

```move
public struct StealthAnnounced has copy, drop {
    pool_id: address,
    announcement_type: u8,      // 0 = deposit, 1 = transfer (matches SDK ANNOUNCEMENT_TYPE_*)
    leaf_index: u64,
    ephemeral_pub: vector<u8>,  // 32 bytes, Ed25519
    encrypted_amount: vector<u8>, // 8 bytes: plaintext u64 LE (type 0) or XOR-encrypted (type 1)
    commitment: vector<u8>,     // 32 bytes, Poseidon(npk, token, amount)
    token_id: vector<u8>,       // 4-byte token id (ZKBTC_TOKEN_ID), little-endian to match SDK
}
```

`transact.move::transact` must accept per-output `ephemeral_pub[]` and `encrypted_amount[]` (or a packed `stealth_payload[]`) from the caller and emit one `StealthAnnounced { announcement_type: 1, ... }` per output, in the same loop that calls `merkle::insert_commitment` (`transact.move:46-50`). The SDK already produces these via `createStealthOutputWithKeys` (`sdk/src/stealth.ts:1018`). **If this Move change cannot land, the indexer scans deposits only and `getNotes` for transfers returns empty — call this out as a known limitation.**

---

## 3. `SuiIndexerStore` interface (extended)

`chains/sui/indexer/src/storage.ts` — extend the existing interface (`storage.ts:4-9`). All methods async; SQLite impl runs them synchronously inside the async signature.

```ts
export interface SuiIndexerStore {
  // --- existing (keep, but reimplement getEventsAfter on the seq column) ---
  getState(packageId: string): Promise<SuiIndexerState | undefined>;
  saveState(state: SuiIndexerState): Promise<void>;

  // --- ingest (single transaction per page) ---
  /** Idempotent upsert of raw events + projection of derived rows, in ONE DB tx. */
  ingestPage(args: {
    packageId: string;
    poolObjectId: string;
    events: NormalizedSuiUtxopiaEvent[];   // already normalized + decoded
    nextCursor?: SuiEventCursor;
    highestCheckpoint?: string;
  }): Promise<{ inserted: number; skippedDuplicates: number }>;

  // --- pool / root reads ---
  getPoolState(packageId: string): Promise<StoredPoolState | undefined>;
  getLatestRoot(packageId: string): Promise<StoredRoot | undefined>;
  getRootByIndex(packageId: string, rootIndex: number): Promise<StoredRoot | undefined>;
  isKnownRoot(packageId: string, root: string): Promise<boolean>;

  // --- note / commitment reads ---
  /** Seek-paginated commitments ordered by seq. Used by scanner + /api/announcements. */
  getCommitments(packageId: string, opts: {
    afterSeq?: number;
    afterLeafIndex?: number;   // for `since` semantics of legacy announcements API
    announcementType?: 0 | 1;
    limit?: number;            // default 500, max 2000
  }): Promise<StoredCommitment[]>;
  getCommitmentByLeafIndex(packageId: string, leafIndex: number): Promise<StoredCommitment | undefined>;

  // --- nullifiers ---
  hasNullifier(packageId: string, nullifier: string): Promise<boolean>;
  getNullifiersAfter(packageId: string, afterSeq?: number, limit?: number): Promise<StoredNullifier[]>;

  // --- redemptions ---
  getRedemption(packageId: string, redemptionId: number): Promise<StoredRedemption | undefined>;
  listRedemptions(packageId: string, status?: RedemptionStatus, limit?: number): Promise<StoredRedemption[]>;

  // --- ops / health ---
  getSyncMeta(packageId: string): Promise<SyncMeta>;   // last seq, checkpoint, lag, counts
  /** Replay/rebuild: re-run projections from raw_events (DELETE projected tables, replay). */
  rebuildProjections(packageId: string): Promise<{ replayed: number }>;
}
```

Supporting row types (`chains/sui/indexer/src/types.ts`):

```ts
export interface StoredPoolState {
  packageId: string; poolObjectId: string; treeDepth: number; paused: boolean;
  latestRoot: string; latestRootIndex: number; nextLeafIndex: number; version?: number;
}
export interface StoredRoot { rootIndex: number; root: string; checkpoint?: string; timestampMs?: number; }
export interface StoredCommitment {
  leafIndex: number; commitment: string; announcementType: 0 | 1 | null;
  ephemeralPub?: string; encryptedAmount?: string; tokenId?: string;
  amountSats?: string; depositTxid?: string; depositVout?: number;
  sourceTxDigest: string; checkpoint?: string; timestampMs?: number; seq: number;
}
export interface StoredNullifier { nullifier: string; sourceTxDigest: string; seq: number; }
export type RedemptionStatus = "requested" | "approved" | "completed";
export interface StoredRedemption {
  redemptionId: number; status: RedemptionStatus; btcAddressHash?: string;
  amountSats?: string; maxFeeSats?: string; sighash?: string; btcTxid?: string;
}
export interface SyncMeta {
  lastSeq: number; lastCheckpoint?: string; lastCursor?: SuiEventCursor;
  eventsIngested: number; chainTipCheckpoint?: string; lagCheckpoints?: number; updatedAt: number;
}
```

---

## 4. Reliable event sync

### 4.1 Normalization (extend `sui-event-source.ts`)

`SuiUtxopiaEventSource.normalize` (`chains/sui/indexer/src/sui-event-source.ts:65-81`) currently drops `checkpoint` and `timestampMs`. Fix:

- Set `cursor.checkpoint = event.checkpoint` and capture `event.timestampMs` (both are present on `SuiEvent` from `@mysten/sui`).
- Add `StealthAnnounced` to `KNOWN_EVENT_TYPES` (`sui-event-source.ts:10-22`) and `SuiUtxopiaEventType` (`types.ts:1-12`).
- Decode `vector<u8>` fields: `@mysten/sui` returns Move `vector<u8>` in `parsedJson` as either a number[] or base64 — normalize to **lowercase hex string** here so storage/scanner never re-parse. Centralize in a `hexFromMoveBytes(v): string` helper.

### 4.2 Sync loop (`service.ts` — replace `syncOnce`)

```ts
async drainToTip(): Promise<{ ingested: number; pages: number }> {
  let cursor = (await store.getState(pkg))?.lastCursor;
  let ingested = 0, pages = 0;
  for (;;) {
    const page = await source.poll(cursor);                 // queryEvents, ascending
    const decoded = page.events;                            // already normalized+hex
    const { inserted } = await store.ingestPage({
      packageId: pkg, poolObjectId: pool, events: decoded,
      nextCursor: page.nextCursor, highestCheckpoint: maxCheckpoint(decoded),
    });
    ingested += inserted; pages++;
    if (!page.hasNextPage || !page.nextCursor) break;        // FIX: drain all pages
    cursor = page.nextCursor;                                // FIX: advance even on partial pages
  }
  return { ingested, pages };
}
```

Driver loop (replace `server.ts:31-45`): call `drainToTip()` on an interval (`UTXOPIA_SUI_INDEXER_POLL_MS`, default 2000ms), single-flight guard (`syncing` boolean already present at `server.ts:31`), exponential backoff on RPC error (cap 30s), structured log per page.

### 4.3 Idempotency, gaps, and "reorg" handling

Sui is **deterministically final at checkpoint**; there are no probabilistic reorgs like Bitcoin. The risks are operational, not consensus:

1. **Duplicate delivery / cursor replay**: `raw_events` has `unique (tx_digest, event_seq)`; `ingestPage` uses `INSERT OR IGNORE` and returns the real inserted count. Projections are derived only from rows that were actually inserted (the `RETURNING`/changes count), so re-ingesting a page is a no-op.

2. **Gap detection**: After each `ingestPage`, compare `commitments` row count to `pool_state.next_leaf_index`. Commitments are dense (leaf_index increments by 1, see `pool.move:64-66`). If `MAX(leaf_index)+1 != COUNT(*)` for any contiguous prefix, a gap exists → log error, and on next loop **re-poll from the cursor before the gap** (we keep the cursor that produced the last contiguous leaf). Same dense-index check for `merkle_roots.root_index`.

3. **RPC node failover / pruning**: if `queryEvents` returns an error indicating the cursor is unknown (pruned node), fail over to a backup RPC URL (`UTXOPIA_SUI_RPC_URLS` comma-list). Never reset the cursor to null on a transient error — only an explicit `rebuildProjections` + re-scan from genesis cursor is allowed, gated behind an admin op.

4. **Checkpoint monotonicity assertion**: store `last_checkpoint`; assert each new page's max checkpoint `>=` stored. A decrease implies a misbehaving/forked RPC node → alarm + failover, do not ingest.

5. **Crash safety**: cursor + projections are written in the **same SQLite transaction** as the raw events (`ingestPage` is one `db.transaction(...)`). A crash mid-page either commits the whole page or none; on restart we resume from the last committed cursor. No partial-page divergence (this is the bug in current `service.ts:15-21`, which saves events then state non-atomically and only when `nextCursor` exists).

### 4.4 Projection rules (inside `ingestPage`, per event type)

| Event | Projection |
|-------|-----------|
| `PoolCreated` | upsert `pool_state` (tree_depth, version) |
| `PoolPaused` | update `pool_state.paused` |
| `BtcDepositVerified` | insert `commitments` row: `announcement_type=0`, `ephemeral_pub`, `npk`→(not stored separately; npk recoverable by scanner), `commitment`, `amount_sats` (plaintext), `deposit_txid/vout`; also set `encrypted_amount` = `amount_sats` as 8-byte LE hex so the unified scanner path is uniform |
| `CommitmentInserted` | if a `commitments` row for `leaf_index` already exists (from `BtcDepositVerified` or `StealthAnnounced` in same tx) → no-op; else insert a bare row (`announcement_type=null`) as a placeholder (still serves merkle membership) |
| `StealthAnnounced` | insert/upsert `commitments` row: `announcement_type=1`, `ephemeral_pub`, `encrypted_amount`, `commitment`, `token_id` |
| `MerkleRootUpdated` | insert `merkle_roots`; update `pool_state.latest_root`/`latest_root_index` if newer |
| `NullifierSpent` | insert `nullifiers` |
| `RedemptionRequested` | upsert `redemptions` (status `requested`, btc_address_hash, amounts) |
| `IkaSigningApproved` | update `redemptions` → status `approved`, set `sighash` (only if not already `completed`) |
| `RedemptionCompleted` | update `redemptions` → status `completed`, set `btc_txid` |
| `VerifyingKeyRegistered`, `JoinSplitVerified` | raw log only (no projection needed for SDK queries; keep for audit) |

Ordering within a page is `raw_events.seq` ascending; a deposit and its `CommitmentInserted` may arrive in the same tx — process `BtcDepositVerified`/`StealthAnnounced` BEFORE the bare `CommitmentInserted` placeholder by event-type priority within equal `(tx_digest)` so the rich row wins. Implement by sorting page events `[Deposit/Stealth] before [CommitmentInserted]` when `tx_digest` matches, or simply use `INSERT ... ON CONFLICT DO UPDATE` that only overwrites null fields.

---

## 5. Note scanning

### 5.1 Algorithm (mirror `scanUnifiedNotes`, `sdk/src/stealth.ts:829-902`)

Note scanning is performed **client-side in the SDK by default** (the viewing key never leaves the wallet for self-custody). The indexer offers TWO modes:

- **Mode A (default, trustless): serve raw announcements.** `GET /api/announcements` returns commitment rows (`announcement_type`, `ephemeral_pub`, `encrypted_amount`, `commitment`, `leaf_index`, `block_time`). The SDK's `scanUnifiedNotes` does the ECDH + npk/commitment match locally. The indexer never sees the viewing key. THIS IS THE REQUIRED PATH FOR PARITY — it preserves the same trust model as Solana.

- **Mode B (opt-in convenience): server-side scan with a viewing key.** Only if the operator runs a *private* indexer for a single user (e.g. self-hosted). `getNotes({viewingKey})` runs the same algorithm server-side. Must be DISABLED on any shared/public deployment (config flag `UTXOPIA_SUI_INDEXER_ALLOW_VIEWKEY_SCAN=false` default). Document the privacy caveat loudly.

The scan algorithm (identical to `scanUnifiedNotes`, reusing `@utxopia/sdk` exports so logic is not re-derived):

For each commitment row with `announcement_type != null`:
1. `sharedSecret = x25519Ecdh(viewingPrivKey, ephemeralPub)` (`stealth.ts:844`).
2. Amount:
   - type 0 (deposit): `amount = u64 LE` of `encrypted_amount` (`stealth.ts:850-851`).
   - type 1 (transfer): `amount = decryptAmount(encrypted_amount, sharedSecret)` (XOR, `stealth.ts:854`).
3. Range check `0 < amount <= 21e6 * 1e8` (`stealth.ts:837,857`).
4. `mpk = computeMPKSync(spendingPub.x, spendingPub.y, nullifyingKey)`; `stealthScalar = deriveStealthScalar(sharedSecret)`; `npk = computeNPKSync(mpk, stealthScalar)`; `commitment' = computeJoinSplitCommitmentSync(npk, tokenId, amount)` (`stealth.ts:839,862-864`).
5. Deposit (type 0): require `commitment' == on-chain commitment` else skip (`stealth.ts:869-873`). Transfer (type 1): a wrong key yields garbage amount already filtered in step 3.
6. Emit `Note` with `{commitment, leafIndex, amount, tokenId}`. Nullifier is `computeJoinSplitNullifierSync(nullifyingKey, leafIndex)` (`stealth.ts:1074`) — only computable with the nullifying key; in Mode A the SDK does this, in Mode B requires the key be supplied.

### 5.2 Spent-note filtering

After scanning, mark a note **spent** if its computed nullifier exists in the `nullifiers` table (`hasNullifier`). `getNotes` returns only unspent notes by default; `?includeSpent=true` returns all with a `spent` boolean.

### 5.3 `tokenId`

Default `ZKBTC_TOKEN_ID = 0x7a627463` ("zkbtc", CLAUDE.md). Token id is carried on `StealthAnnounced.token_id` and on deposit rows it is implicitly zkBTC. Honor `NoteScanInput.tokenIds` (`packages/sdk-core/src/chain-adapter.ts:30-34`) to filter.

### 5.4 Poseidon / field-element correctness

The indexer (Mode B) must produce commitments **bit-identical to the on-chain Move `sui::poseidon::poseidon_bn254`** and the circom circuit. Reuse the SDK's `computeJoinSplitCommitmentSync` (already circuit-matched against Solana). Do NOT reimplement Poseidon in the indexer. Inputs must be canonicalized `< BN254 field modulus` before hashing (the SDK already does this); never feed a 32-byte value `>= p`. For Mode A this is irrelevant (no hashing server-side).

---

## 6. HTTP API contract

Base: `http://host:PORT`. All responses `application/json`. All 32-byte values are lowercase hex (no `0x`). Amounts are decimal strings. CORS enabled for the web app origin.

### 6.1 Ops

- `GET /health` → `{ ok, packageId, poolObjectId, lastSeq, lastCheckpoint, lagCheckpoints, eventsIngested }`
- `GET /sync` → `SyncMeta`
- `POST /admin/rebuild` (auth via `X-Admin-Token`) → `{ replayed }` (runs `rebuildProjections`)

### 6.2 Pool / roots (consumed by `UTXOpiaSuiAdapter.getPoolState`/`getLatestMerkleRoot`)

- `GET /pool` →
  ```json
  { "chain":"sui","poolId":"0x..","paused":false,
    "latestMerkleRoot":"<64hex>","latestRootIndex":12,"treeDepth":16,"nextLeafIndex":42 }
  ```
  Maps directly into `PoolState` (`chain-adapter.ts:7-13`). Replaces hardcoded return at `sui-adapter.ts:48-56`.
- `GET /merkle/root` → `{ "root":"<64hex>","index":12,"observedAt":"<iso>" }` (→ `MerkleRoot`, `chain-adapter.ts:15-19`; replaces `sui-adapter.ts:58-64`).
- `GET /merkle/root/:index` → same shape for a historical root (membership-window checks).

### 6.3 Notes / announcements

- **Legacy parity (REQUIRED):** `GET /api/announcements?since=<leafIndex>` →
  ```json
  { "success": true,
    "announcements": [
      { "announcement_type": 1, "ephemeral_pub":"<64hex>",
        "encrypted_amount":"<16hex>", "commitment":"<64hex>",
        "leaf_index": 42, "token_id":"7a627463", "block_time": 1717000000 }
    ] }
  ```
  This exactly matches what the SDK's `AnnouncementClient.fetchFromBackend` expects (`sdk/src/announcement-client.ts:220-237`) and `parseAnnouncementsFromHex` (`sdk/src/stealth.ts:1092`). `since` filters `leaf_index > since`. This lets the existing SDK note-scan pipeline work against the Sui indexer with no SDK change. **This is the primary, trustless note path.**
- `GET /api/announcements/ws` (optional): WebSocket push of new announcements (mirrors backend WS at `announcement-client.ts:137`). Phase 2 — polling `since` is sufficient for v1.
- **Mode B (opt-in):** `POST /notes/scan` body `{ viewingKey, spendingPubX?, spendingPubY?, nullifyingKey?, tokenIds?, includeSpent? }` → `Note[]` (`chain-adapter.ts:21-28`). Returns 403 if `ALLOW_VIEWKEY_SCAN=false`. Used by `UTXOpiaSuiAdapter.getNotes` (replaces throw at `sui-adapter.ts:66-72`) ONLY when the adapter is configured for a private indexer; otherwise the adapter fetches `/api/announcements` and scans locally.

### 6.4 Nullifiers

- `GET /api/nullifiers?since=<seq>` → `{ success:true, nullifiers:[{nullifier:"<64hex>", seq:Number}], cursor:Number }` (mirrors backend `/api/nullifiers` used by `event-client.ts:119`).

### 6.5 Redemptions

- `GET /redemptions/:id` →
  ```json
  { "redemptionId": 3, "status":"approved",
    "btcAddressHash":"<hex>","amountSats":"100000","maxFeeSats":"2000",
    "sighash":"<64hex>","btcTxid":null }
  ```
- `GET /redemptions?status=requested` → array of the above.

### 6.6 Raw events (keep existing, fix pagination)

- `GET /events?afterSeq=<n>&type=<EventType>&limit=<n>` → seek-paginated `raw_events` ordered by `seq` (replaces the JS `findIndex` scan at `api.ts:19`/`storage.ts:138-174`). Response includes `nextAfterSeq`.

---

## 7. Backfill / rebuild

- **Cold start / backfill:** with `last_cursor = null`, `drainToTip()` paginates from the genesis of the package's `events` module. For a fresh pool this is a few pages; for an existing one, page size 50 (current `sui-event-source.ts:49`) → bump default to 200 (RPC max for `queryEvents`), wrap in the same idempotent ingest. Backfill is just sync with no cursor.
- **Projection rebuild:** `rebuildProjections` truncates `commitments/merkle_roots/nullifiers/pool_state/redemptions` (NOT `raw_events`) and replays every `raw_events` row through the projection switch in `seq` order, inside one transaction. Use this after a projection-logic bugfix without re-hitting RPC. Exposed via `POST /admin/rebuild`.
- **Full resync from chain:** delete the DB file (or `DELETE FROM raw_events`) and restart — sync re-fetches from genesis. Document as the recovery-of-last-resort.

---

## 8. Gas / performance

The indexer does no on-chain writes (read-only RPC consumer), so no Sui gas. Perf concerns:

| Concern | Mitigation |
|---------|-----------|
| `queryEvents` page size | 200/page; drain to tip; backoff on 429/5xx |
| Full-scan `getEventsAfter` (current bug, `storage.ts:138-174`) | replaced by indexed seek on `seq` |
| `getNotes` Mode A volume | seek pagination via `since=leafIndex`; client caches like `AnnouncementClient` already does (`announcement-client.ts:120,160`) |
| Mode B server-side ECDH per row | O(rows) X25519 + Poseidon; cap per request (`limit`), cache shared-secret nothing-to-cache (key per request). At depth-16 (65k max leaves) a full scan is <1s; acceptable. Add an optional in-memory LRU of `(viewingKeyHash) → lastScannedSeq` to do incremental scans. |
| SQLite write throughput | WAL + single writer + batched `db.transaction(...)` per page (already the pattern at `storage.ts:121-135`) |
| JSON serialization of big payloads | store pre-hexed strings; no per-request re-encoding of Move bytes |
| Hot `latestMerkleRoot`/`pool` reads | single-row tables, indexed PK; trivially fast |

---

## 9. Risks, edge cases, security pitfalls

1. **Indexer is untrusted — never a fund-safety oracle.** It may serve stale/wrong roots if compromised. The SDK MUST verify any merkle path it builds against the on-chain `pool.latest_root` (read via Sui RPC) before submitting a `transact` — the indexer root is a hint only. Document that `getNotes`/`latestMerkleRoot` are availability conveniences. (Parity requirement.)
2. **Missing transfer announcements.** If the `StealthAnnounced` Move event (§2.5) is not added, received transfers are invisible to scanning → users lose access to incoming funds via the indexer (they could still recover from raw chain data manually). HIGH severity dependency — block on the Move change.
3. **Non-atomic cursor advance (current bug).** `service.ts:15-21` saves events then state separately and only when `nextCursor` exists → on the final partial page, progress is lost and the page is re-fetched forever / duplicated. Fixed by `ingestPage` atomicity + always advancing cursor.
4. **Dense-index gap correctness.** Leaf indices and root indices are strictly +1 (`pool.move:64-66,68-72`). A gap means a dropped event → silent fund invisibility / wrong tree. Enforce the dense-prefix invariant (§4.3.2) and alarm on violation; do not advance cursor past a gap.
5. **Field-element canonicalization (Mode B).** Feeding a 32-byte value `>= BN254 p` into Poseidon would mismatch the on-chain commitment. Always reuse SDK helpers that reduce mod p; never hand-roll. (No risk in Mode A.)
6. **Integer overflow.** `amount_sats` and Sui `u64` exceed JS `Number.MAX_SAFE_INTEGER`. Store/serve as decimal strings; parse as `BigInt`. `leaf_index`/`seq` fit i64 but keep them out of float math.
7. **`eventSeq` lexicographic sort trap.** Sui `eventSeq` is a stringified u64; never `ORDER BY event_seq` as text. Use the `seq` surrogate.
8. **Viewing-key leakage (Mode B).** Server-side scan exposes the viewing key (linkability of all the user's notes) to the indexer operator. Default-disabled; require explicit opt-in + private deployment; log a warning at startup if enabled.
9. **Deposit/transfer ambiguity for `CommitmentInserted`.** A bare `CommitmentInserted` with no matching rich event yields an un-scannable placeholder (correct for tree membership, invisible to wallets). Acceptable; the rich event must accompany it for wallet visibility.
10. **RPC node divergence / pruning.** Multi-RPC failover; checkpoint-monotonicity assertion; never blind-reset cursor.
11. **Replay of `RedemptionCompleted` before `IkaSigningApproved`.** Out-of-order delivery is possible across RPC retries; make redemption projection state-machine monotonic (`completed` is terminal; `approved` won't overwrite `completed`).
12. **`block_time` absence.** `event.timestampMs` may be null on some RPC nodes; serve `0` (the SDK tolerates this, `ScannedNote.blockTime ?? 0`, `stealth.ts:891`).

---

## 10. Dependencies on other modules in this design set

- **Move `events`/`transact` spec (REQUIRED):** add + emit `StealthAnnounced` (§2.5). Hard blocker for transfer note scanning.
- **Move `btc_deposit`/`events` spec:** `BtcDepositVerified` already carries the fields needed for deposit scanning (`events.move:21-30`); no change required, but confirm `ephemeral_pubkey`/`npk`/`amount_sats` stay in the event when the BTC-light-client hardening lands.
- **Merkle (Poseidon tree) spec:** the indexer trusts `MerkleRootUpdated` for the canonical root; the on-chain Poseidon tree must emit a root that matches the circuit so the SDK can build valid paths against indexer-served leaves.
- **SDK (`packages/sdk-sui`) spec:** `UTXOpiaSuiAdapter` must consume this API (`getPoolState`→`/pool`, `getLatestMerkleRoot`→`/merkle/root`, `getNotes`→`/api/announcements` + local `scanUnifiedNotes`, or `/notes/scan` in Mode B). Adapter config gains `indexerUrl` (already present, `sui-adapter.ts:40`).
- **`@utxopia/sdk` (Solana SDK) reuse:** import `scanUnifiedNotes`, `decryptAmount`, `computeMPKSync`, `computeNPKSync`, `computeJoinSplitCommitmentSync`, `computeJoinSplitNullifierSync`, `parseAnnouncementsFromHex` rather than re-deriving (Mode B). Keeps Sui scan logic identical to Solana.

---

## 11. Test matrix

### Unit (store / projection)

| # | Case | Assert |
|---|------|--------|
| U1 | `ingestPage` duplicate `(txDigest,eventSeq)` | inserted=0 on 2nd call; projections unchanged |
| U2 | `BtcDepositVerified` projection | commitments row: type=0, plaintext amount, deposit_txid/vout, ephemeral_pub set |
| U3 | `StealthAnnounced` projection | commitments row: type=1, encrypted_amount, token_id |
| U4 | `CommitmentInserted` after rich event same tx | no overwrite of rich fields (ON CONFLICT keeps non-null) |
| U5 | bare `CommitmentInserted` only | placeholder row, type=null |
| U6 | `MerkleRootUpdated` | merkle_roots row + pool_state.latest_root advances; older root index ignored |
| U7 | `NullifierSpent` | nullifiers row; `hasNullifier` true |
| U8 | redemption lifecycle requested→approved→completed | status monotonic; out-of-order completed-before-approved still terminal-correct |
| U9 | dense-index gap (skip leaf 5) | gap detector flags; cursor not advanced past gap |
| U10 | atomic crash sim (throw mid-tx) | nothing committed; cursor unchanged |
| U11 | seek pagination `getCommitments(afterSeq)` | returns strictly seq-ordered, correct slice, respects limit |
| U12 | u64 amount > 2^53 | round-trips as decimal string, no precision loss |

### Unit (scanner — Mode B)

| # | Case | Assert |
|---|------|--------|
| S1 | deposit row, correct keys | note found, amount == plaintext, commitment matches |
| S2 | deposit row, wrong viewing key | skipped (commitment mismatch) |
| S3 | transfer row, correct keys | amount decrypts in range, note found |
| S4 | transfer row, wrong key | garbage amount out of range → skipped |
| S5 | amount=0 / amount>21e6 BTC | skipped |
| S6 | spent note (nullifier present) | excluded unless `includeSpent` |
| S7 | tokenIds filter | only matching token notes returned |
| S8 | parity: indexer scan vs SDK `scanUnifiedNotes` on same rows | identical note set |

### Integration (against Sui localnet / regtest-flow)

| # | Case | Assert |
|---|------|--------|
| I1 | run `chains/sui/scripts/regtest-flow.ts`, sync indexer | deposit appears in `/api/announcements`, scannable |
| I2 | restart indexer mid-sync | resumes from cursor, no dup/gap, projections consistent |
| I3 | `rebuildProjections` after manual projection wipe | byte-identical projected tables vs pre-wipe |
| I4 | RPC failover (kill primary RPC) | switches to backup, continues |
| I5 | `GET /pool` / `/merkle/root` vs on-chain `pool` object | match |
| I6 | transfer (transact) → `StealthAnnounced` → recipient scans note | recipient sees incoming note (validates §2.5 end-to-end) |
| I7 | redemption request→approve→complete via PTBs | `/redemptions/:id` reflects each transition |
| I8 | legacy SDK `AnnouncementClient` pointed at indexer | fetches + scans with no SDK change |
| I9 | 200-page backfill on a pre-populated pool | all leaves dense, counts match `next_leaf_index` |

---

## 12. Effort & open questions

**Effort: 7-10 developer-days.**
- Schema + `ingestPage`/projections + interface: ~2.5d
- Sync loop hardening (drain, atomic cursor, gap/failover): ~2d
- HTTP API (pool/root/announcements/redemptions/nullifiers/events): ~1.5d
- Mode B scanner (SDK reuse) + Mode A passthrough + filtering: ~1.5d
- Tests (unit + integration incl. regtest-flow wiring): ~2d
- (Excludes the Move `StealthAnnounced` change — tracked under the `transact`/`events` Move spec; ~0.5d there.)

**Open questions:**
1. Is the Move `StealthAnnounced` event in-scope for the contracts hardening sprint, or must the indexer ship deposit-only scanning first? (Determines whether I6/I8 transfer cases are v1 or v2.)
2. Public vs private indexer deployment model — does any production deployment ever enable Mode B (server-side viewing-key scan), or is it strictly a self-host convenience? Affects whether `/notes/scan` ships at all.
3. WebSocket push (`/api/announcements/ws`) for v1, or is `since`-polling acceptable until a later phase? (SDK `AnnouncementClient` supports both; polling is simpler and sufficient.)
4. Token model: is zkBTC the only token on Sui (single `token_id`), or will multi-token shielding land? If single-token, `token_id` columns can default to `ZKBTC_TOKEN_ID` and the `StealthAnnounced.token_id` field is optional.
5. Multi-pool: one DB per pool, or shared DB keyed by `package_id`? Schema supports shared; default deployment is one-pool-one-DB.
6. Postgres: ship the PG driver in v1 or document-only? Recommend SQLite-only for v1, PG as a fast-follow if an operator needs read replicas.
