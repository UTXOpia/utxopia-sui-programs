import { Database } from "bun:sqlite";
import type { NormalizedSuiUtxopiaEvent } from "./types";

/**
 * Derived, queryable state built from the raw event stream — the surface the SDK reads
 * for note scanning and pool state. Projections are applied transactionally per ingested
 * batch so the indexer is restart-safe and never half-applies a page.
 *
 * IMPORTANT (matches spec 06 risk E2): this is a convenience/availability layer, NOT a
 * fund-safety oracle. The SDK MUST re-verify any Merkle path against the on-chain
 * `pool.latest_root` (live RPC) before submitting a transact; roots here are hints.
 *
 * Note scanning is Mode A (trustless): the indexer serves the raw deposit/transfer
 * commitment rows (ephemeral_pub + amount/encrypted-amount + leaf index); the SDK does the
 * viewing-key/npk match client-side. The viewing key never reaches the indexer.
 *
 * Expected payload keys are the Move event field names (snake_case) emitted by
 * `events.move`: leaf_index, commitment, root, root_index, nullifier, redemption_id,
 * amount_sats, max_fee_sats, btc_address_hash, ephemeral_pubkey, npk, btc_txid, paused.
 */
export interface PoolStateProjection {
  packageId: string;
  paused: boolean;
  latestRoot: string;
  rootIndex: number;
  leafCount: number;
}

export interface CommitmentRow {
  leafIndex: number;
  commitment: string;
  kind: "deposit" | "transfer" | "unknown";
  ephemeralPub: string;
  /** Plaintext sats for deposits; XOR-encrypted for transfers (decoded by the SDK). */
  amount: string;
  txDigest: string;
}

export interface RedemptionRow {
  redemptionId: number;
  amount: string;
  maxFee: string;
  btcScript: string;
  status: "pending" | "completed";
  btcTxid: string;
}

export class SqliteProjections {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
    this.db.exec(`
      create table if not exists pool_projection (
        package_id text primary key,
        paused integer not null default 0,
        latest_root text not null default '',
        root_index integer not null default 0,
        leaf_count integer not null default 0
      );
      create table if not exists commitment_projection (
        package_id text not null,
        leaf_index integer not null,
        commitment text not null,
        kind text not null default 'unknown',
        ephemeral_pub text not null default '',
        amount text not null default '',
        tx_digest text not null default '',
        primary key (package_id, leaf_index)
      );
      create table if not exists nullifier_projection (
        package_id text not null,
        nullifier text not null,
        primary key (package_id, nullifier)
      );
      create table if not exists redemption_projection (
        package_id text not null,
        redemption_id integer not null,
        amount text not null default '0',
        max_fee text not null default '0',
        btc_script text not null default '',
        status text not null default 'pending',
        btc_txid text not null default '',
        primary key (package_id, redemption_id)
      );
    `);
  }

  /** Apply a batch of events to the projections atomically (all-or-nothing). */
  apply(events: NormalizedSuiUtxopiaEvent[]): void {
    const run = this.db.transaction((items: NormalizedSuiUtxopiaEvent[]) => {
      for (const e of items) this.applyOne(e);
    });
    run(events);
  }

  private applyOne(e: NormalizedSuiUtxopiaEvent): void {
    const pkg = e.packageId;
    const p = e.payload;
    switch (e.type) {
      case "PoolCreated":
        this.ensurePool(pkg);
        break;
      case "PoolPaused":
        this.ensurePool(pkg);
        this.db.query(`update pool_projection set paused = ? where package_id = ?`).run(bool(p.paused) ? 1 : 0, pkg);
        break;
      case "MerkleRootUpdated":
        this.ensurePool(pkg);
        this.db
          .query(`update pool_projection set latest_root = ?, root_index = ? where package_id = ?`)
          .run(str(p.root), num(p.root_index), pkg);
        break;
      case "CommitmentInserted": {
        this.ensurePool(pkg);
        const leaf = num(p.leaf_index);
        this.db
          .query(
            `insert into commitment_projection (package_id, leaf_index, commitment, tx_digest)
             values (?, ?, ?, ?)
             on conflict(package_id, leaf_index) do update set commitment = excluded.commitment`,
          )
          .run(pkg, leaf, str(p.commitment), e.cursor.transactionDigest);
        this.db
          .query(`update pool_projection set leaf_count = max(leaf_count, ?) where package_id = ?`)
          .run(leaf + 1, pkg);
        break;
      }
      case "BtcDepositVerified": {
        // Enrich the commitment row at this leaf with deposit scan data (plaintext amount).
        const leaf = num(p.leaf_index);
        this.db
          .query(
            `insert into commitment_projection (package_id, leaf_index, commitment, kind, ephemeral_pub, amount, tx_digest)
             values (?, ?, ?, 'deposit', ?, ?, ?)
             on conflict(package_id, leaf_index) do update set
               kind = 'deposit',
               ephemeral_pub = excluded.ephemeral_pub,
               amount = excluded.amount`,
          )
          .run(pkg, leaf, str(p.commitment), str(p.ephemeral_pubkey), str(p.amount_sats), e.cursor.transactionDigest);
        break;
      }
      case "NullifierSpent":
        this.db
          .query(`insert or ignore into nullifier_projection (package_id, nullifier) values (?, ?)`)
          .run(pkg, str(p.nullifier));
        break;
      case "RedemptionRequested":
        this.db
          .query(
            `insert into redemption_projection (package_id, redemption_id, amount, max_fee, btc_script, status)
             values (?, ?, ?, ?, ?, 'pending')
             on conflict(package_id, redemption_id) do nothing`,
          )
          .run(pkg, num(p.redemption_id), str(p.amount_sats), str(p.max_fee_sats), str(p.btc_address_hash));
        break;
      case "RedemptionCompleted":
        this.db
          .query(`update redemption_projection set status = 'completed', btc_txid = ? where package_id = ? and redemption_id = ?`)
          .run(str(p.btc_txid), pkg, num(p.redemption_id));
        break;
      default:
        break; // IkaSigningApproved / VerifyingKeyRegistered / JoinSplitVerified: no projection
    }
  }

  private ensurePool(pkg: string): void {
    this.db.query(`insert or ignore into pool_projection (package_id) values (?)`).run(pkg);
  }

  // ---- queries (the SDK-facing read API) ----

  getPoolState(packageId: string): PoolStateProjection | undefined {
    const row = this.db
      .query<{ paused: number; latest_root: string; root_index: number; leaf_count: number }, [string]>(
        `select paused, latest_root, root_index, leaf_count from pool_projection where package_id = ?`,
      )
      .get(packageId);
    if (!row) return undefined;
    return {
      packageId,
      paused: row.paused === 1,
      latestRoot: row.latest_root,
      rootIndex: row.root_index,
      leafCount: row.leaf_count,
    };
  }

  /** Commitment leaves from `fromLeaf` onward — the raw input to client-side note scan. */
  getCommitments(packageId: string, fromLeaf = 0): CommitmentRow[] {
    return this.db
      .query<
        { leaf_index: number; commitment: string; kind: string; ephemeral_pub: string; amount: string; tx_digest: string },
        [string, number]
      >(
        `select leaf_index, commitment, kind, ephemeral_pub, amount, tx_digest
         from commitment_projection where package_id = ? and leaf_index >= ? order by leaf_index asc`,
      )
      .all(packageId, fromLeaf)
      .map((r) => ({
        leafIndex: r.leaf_index,
        commitment: r.commitment,
        kind: r.kind as CommitmentRow["kind"],
        ephemeralPub: r.ephemeral_pub,
        amount: r.amount,
        txDigest: r.tx_digest,
      }));
  }

  isNullifierSpent(packageId: string, nullifier: string): boolean {
    const row = this.db
      .query<{ c: number }, [string, string]>(
        `select count(*) as c from nullifier_projection where package_id = ? and nullifier = ?`,
      )
      .get(packageId, nullifier);
    return (row?.c ?? 0) > 0;
  }

  getRedemption(packageId: string, redemptionId: number): RedemptionRow | undefined {
    const row = this.db
      .query<
        { redemption_id: number; amount: string; max_fee: string; btc_script: string; status: string; btc_txid: string },
        [string, number]
      >(
        `select redemption_id, amount, max_fee, btc_script, status, btc_txid
         from redemption_projection where package_id = ? and redemption_id = ?`,
      )
      .get(packageId, redemptionId);
    if (!row) return undefined;
    return {
      redemptionId: row.redemption_id,
      amount: row.amount,
      maxFee: row.max_fee,
      btcScript: row.btc_script,
      status: row.status as RedemptionRow["status"],
      btcTxid: row.btc_txid,
    };
  }
}

function num(v: unknown): number {
  if (typeof v === "number") return v;
  if (typeof v === "string") return Number(v);
  if (typeof v === "bigint") return Number(v);
  return 0;
}

function str(v: unknown): string {
  if (v == null) return "";
  if (typeof v === "string") return v;
  return String(v);
}

function bool(v: unknown): boolean {
  return v === true || v === 1 || v === "1" || v === "true";
}
