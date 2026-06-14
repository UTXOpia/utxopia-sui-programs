import type { NormalizedSuiUtxopiaEvent, SuiEventCursor, SuiIndexerState } from "./types";
import { Database } from "bun:sqlite";

export interface SuiIndexerStore {
  getState(packageId: string): Promise<SuiIndexerState | undefined>;
  saveState(state: SuiIndexerState): Promise<void>;
  saveEvents(events: NormalizedSuiUtxopiaEvent[]): Promise<void>;
  getEventsAfter(cursor?: SuiEventCursor): Promise<NormalizedSuiUtxopiaEvent[]>;
}

export class InMemorySuiIndexerStore implements SuiIndexerStore {
  private readonly states = new Map<string, SuiIndexerState>();
  private readonly events: NormalizedSuiUtxopiaEvent[] = [];

  async getState(packageId: string): Promise<SuiIndexerState | undefined> {
    return this.states.get(packageId);
  }

  async saveState(state: SuiIndexerState): Promise<void> {
    this.states.set(state.packageId, state);
  }

  async saveEvents(events: NormalizedSuiUtxopiaEvent[]): Promise<void> {
    this.events.push(...events);
  }

  async getEventsAfter(cursor?: SuiEventCursor): Promise<NormalizedSuiUtxopiaEvent[]> {
    if (!cursor) {
      return [...this.events];
    }

    const index = this.events.findIndex((event) => sameCursor(event.cursor, cursor));
    if (index < 0) {
      return [...this.events];
    }

    return this.events.slice(index + 1);
  }
}

export class SqliteSuiIndexerStore implements SuiIndexerStore {
  private readonly db: Database;

  constructor(path: string) {
    this.db = new Database(path);
    this.db.exec(`
      create table if not exists sui_indexer_state (
        package_id text primary key,
        last_tx_digest text,
        last_event_seq text,
        last_checkpoint text,
        updated_at integer not null
      );

      create table if not exists sui_utxopia_events (
        tx_digest text not null,
        event_seq text not null,
        checkpoint text,
        timestamp_ms text,
        event_type text not null,
        package_id text not null,
        pool_object_id text not null,
        payload_json text not null,
        created_at integer not null,
        primary key (tx_digest, event_seq)
      );

      create index if not exists idx_sui_utxopia_events_package_created
        on sui_utxopia_events (package_id, created_at);
      create index if not exists idx_sui_utxopia_events_type
        on sui_utxopia_events (event_type);
    `);
    // Migrate older DBs created before timestamp_ms / last_checkpoint existed.
    addColumnIfMissing(this.db, "sui_utxopia_events", "timestamp_ms", "text");
    addColumnIfMissing(this.db, "sui_indexer_state", "last_checkpoint", "text");
  }

  /** Shared handle so projections can commit in the same sqlite db (PLAN.md). */
  get database(): Database {
    return this.db;
  }

  async getState(packageId: string): Promise<SuiIndexerState | undefined> {
    const row = this.db
      .query<{ last_tx_digest: string | null; last_event_seq: string | null; last_checkpoint: string | null }, [string]>(
        "select last_tx_digest, last_event_seq, last_checkpoint from sui_indexer_state where package_id = ?",
      )
      .get(packageId);
    if (!row?.last_tx_digest || !row.last_event_seq) return undefined;
    return {
      packageId,
      lastCursor: {
        transactionDigest: row.last_tx_digest,
        eventSequence: row.last_event_seq,
        // Carries the opaque GraphQL page cursor when the GraphQL source is in use.
        checkpoint: row.last_checkpoint ?? undefined,
      },
    };
  }

  async saveState(state: SuiIndexerState): Promise<void> {
    this.db
      .query(`
        insert into sui_indexer_state (package_id, last_tx_digest, last_event_seq, last_checkpoint, updated_at)
        values (?, ?, ?, ?, ?)
        on conflict(package_id) do update set
          last_tx_digest = excluded.last_tx_digest,
          last_event_seq = excluded.last_event_seq,
          last_checkpoint = excluded.last_checkpoint,
          updated_at = excluded.updated_at
      `)
      .run(
        state.packageId,
        state.lastCursor?.transactionDigest ?? null,
        state.lastCursor?.eventSequence ?? null,
        state.lastCursor?.checkpoint ?? null,
        Date.now(),
      );
  }

  async saveEvents(events: NormalizedSuiUtxopiaEvent[]): Promise<void> {
    const insert = this.db.query(`
      insert or ignore into sui_utxopia_events (
        tx_digest,
        event_seq,
        checkpoint,
        timestamp_ms,
        event_type,
        package_id,
        pool_object_id,
        payload_json,
        created_at
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    const tx = this.db.transaction((items: NormalizedSuiUtxopiaEvent[]) => {
      for (const event of items) {
        insert.run(
          event.cursor.transactionDigest,
          event.cursor.eventSequence,
          event.cursor.checkpoint ?? null,
          event.timestampMs ?? null,
          event.type,
          event.packageId,
          event.poolObjectId,
          JSON.stringify(event.payload),
          Date.now(),
        );
      }
    });
    tx(events);
  }

  async getEventsAfter(cursor?: SuiEventCursor): Promise<NormalizedSuiUtxopiaEvent[]> {
    const rows = this.db
      .query<{
        tx_digest: string;
        event_seq: string;
        checkpoint: string | null;
        timestamp_ms: string | null;
        event_type: NormalizedSuiUtxopiaEvent["type"];
        package_id: string;
        pool_object_id: string;
        payload_json: string;
      }, []>(`
        select tx_digest, event_seq, checkpoint, timestamp_ms, event_type, package_id, pool_object_id, payload_json
        from sui_utxopia_events
        order by rowid asc
      `)
      .all();

    let start = 0;
    if (cursor) {
      const index = rows.findIndex(
        (row) => row.tx_digest === cursor.transactionDigest && row.event_seq === cursor.eventSequence,
      );
      start = index < 0 ? 0 : index + 1;
    }

    return rows.slice(start).map((row) => ({
      type: row.event_type,
      packageId: row.package_id,
      poolObjectId: row.pool_object_id,
      cursor: {
        checkpoint: row.checkpoint ?? undefined,
        transactionDigest: row.tx_digest,
        eventSequence: row.event_seq,
      },
      timestampMs: row.timestamp_ms ?? undefined,
      payload: JSON.parse(row.payload_json) as Record<string, unknown>,
    }));
  }
}

function sameCursor(a: SuiEventCursor, b: SuiEventCursor): boolean {
  return a.transactionDigest === b.transactionDigest && a.eventSequence === b.eventSequence;
}

/** Idempotent column migration for DBs created before a column was added. */
function addColumnIfMissing(db: Database, table: string, column: string, type: string): void {
  const cols = db.query<{ name: string }, []>(`pragma table_info(${table})`).all();
  if (!cols.some((c) => c.name === column)) {
    db.exec(`alter table ${table} add column ${column} ${type}`);
  }
}
