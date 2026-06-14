//! Server-side explorer projections — the same shapes `web/lib/sui/explorer.ts`
//! computes client-side today, moved into the indexer so the web becomes a thin reader
//! (events → DB → web). Operates on the indexer's stored `NormalizedSuiUtxopiaEvent[]`
//! (payload = the Move event's parsedJson with snake_case fields; vector<u8> as number[]).

import type { NormalizedSuiUtxopiaEvent } from "./types";

export interface ExplorerTx {
  txSignature: string;
  type: "shield" | "transfer" | "unshield" | "withdraw";
  tokenId: string | null;
  tokenSymbol: string | null;
  timestamp: number;
  status: string;
  inputs: Record<string, unknown>[];
  outputs: Record<string, unknown>[];
  btcMeta?: Record<string, unknown> | null;
}

export interface ExplorerStats {
  /** decimal strings (sats) — JSON-safe bigints */
  totalShielded: string;
  volume: string;
  depositCount: number;
  totalCommitments: number;
}

export interface ExplorerProjectionOptions {
  poolAddress?: string | null;
}

export function buildExplorerStats(events: NormalizedSuiUtxopiaEvent[]): ExplorerStats {
  const commitments = new Set<string>();
  let maxLeafIndex = -1;
  let totalShielded = 0n;
  let depositCount = 0;
  let redeemed = 0n;

  for (const e of events) {
    const p = e.payload;
    if (e.type === "CommitmentInserted") {
      const commitment = bytesField(p.commitment);
      if (commitment) commitments.add(commitment);
      const leafIndex = bigintField(p.leaf_index);
      if (leafIndex != null && leafIndex <= BigInt(Number.MAX_SAFE_INTEGER)) {
        maxLeafIndex = Math.max(maxLeafIndex, Number(leafIndex));
      }
    } else if (e.type === "BtcDepositVerified") {
      const amount = bigintField(p.amount_sats);
      if (amount != null) {
        totalShielded += amount;
        depositCount += 1;
      }
    } else if (e.type === "RedemptionRequested") {
      const amount = bigintField(p.amount_sats);
      if (amount != null) redeemed += amount;
    }
  }

  const totalCommitments = Math.max(commitments.size, maxLeafIndex + 1, 0);
  return {
    totalShielded: (totalShielded > redeemed ? totalShielded - redeemed : 0n).toString(),
    volume: (totalShielded + redeemed).toString(),
    depositCount,
    totalCommitments,
  };
}

export function buildExplorerTransactions(
  events: NormalizedSuiUtxopiaEvent[],
  opts: ExplorerProjectionOptions = {},
): ExplorerTx[] {
  const grouped = new Map<string, NormalizedSuiUtxopiaEvent[]>();
  for (const e of events) {
    const list = grouped.get(e.cursor.transactionDigest) ?? [];
    list.push(e);
    grouped.set(e.cursor.transactionDigest, list);
  }

  const txs: ExplorerTx[] = [];
  const redemptions = new Map<string, { request?: NormalizedSuiUtxopiaEvent; completion?: NormalizedSuiUtxopiaEvent }>();

  for (const [txDigest, txEvents] of grouped) {
    const primary = pickPrimary(txEvents);
    if (!primary) continue;
    const p = primary.payload;
    const timestamp = Number(primary.timestampMs ?? 0);

    if (primary.type === "BtcDepositVerified") {
      txs.push({
        txSignature: txDigest,
        type: "shield",
        tokenId: "zkbtc",
        tokenSymbol: "BTC",
        timestamp,
        status: "confirmed",
        inputs: [{
          grossAmount: numberField(p.amount_sats),
          netAmount: numberField(p.amount_sats),
          btcDepositTxid: bytesField(p.deposit_txid, true),
          depositAmountSats: numberField(p.amount_sats),
        }],
        outputs: [{
          type: "commitment",
          commitment: bytesField(p.commitment),
          leafIndex: numberField(p.leaf_index),
          amount: numberField(p.amount_sats),
        }],
        btcMeta: {
          depositTxid: bytesField(p.deposit_txid, true),
          taprootAddress: opts.poolAddress ?? null,
          mintedSats: numberField(p.amount_sats),
          depositAmountSats: numberField(p.amount_sats),
        },
      });
      continue;
    }

    if (primary.type === "JoinSplitVerified") {
      const nullifiers = txEvents
        .filter((e) => e.type === "NullifierSpent")
        .map((e) => ({ nullifierHash: bytesField(e.payload.nullifier) }));
      const commitments = txEvents
        .filter((e) => e.type === "CommitmentInserted")
        .map((e) => ({
          type: "commitment",
          commitment: bytesField(e.payload.commitment),
          leafIndex: numberField(e.payload.leaf_index),
        }));
      txs.push({
        txSignature: txDigest,
        type: "transfer",
        tokenId: "zkbtc",
        tokenSymbol: "BTC",
        timestamp,
        status: "confirmed",
        inputs: nullifiers,
        outputs: commitments,
      });
      continue;
    }

    if (primary.type === "RedemptionRequested") {
      const id = stringField(p.redemption_id);
      if (id) redemptions.set(id, { ...redemptions.get(id), request: primary });
      continue;
    }

    if (primary.type === "RedemptionCompleted") {
      const id = stringField(p.redemption_id);
      if (id) redemptions.set(id, { ...redemptions.get(id), completion: primary });
    }
  }

  for (const [redemptionId, r] of redemptions) {
    const reqP = r.request?.payload ?? {};
    const compP = r.completion?.payload ?? {};
    const amount = numberField(reqP.amount_sats);
    const fee = numberField(reqP.max_fee_sats);
    txs.push({
      txSignature: r.request?.cursor.transactionDigest ?? r.completion?.cursor.transactionDigest ?? redemptionId,
      type: "withdraw",
      tokenId: "zkbtc",
      tokenSymbol: "BTC",
      timestamp: Number((r.completion ?? r.request)?.timestampMs ?? 0),
      status: r.completion ? "confirmed" : "processing",
      inputs: [{ requestId: redemptionId, grossAmount: amount, fee }],
      outputs: [{
        type: "withdraw",
        amount,
        fee,
        payout: amount == null || fee == null ? undefined : Math.max(0, amount - fee),
        requestId: redemptionId,
        btcScript: bytesField(reqP.btc_script),
        btcTxid: bytesField(compP.btc_txid, true),
        localStatus: r.completion ? "Completed" : "Processing",
      }],
    });
  }

  txs.sort((a, b) => b.timestamp - a.timestamp);
  return txs;
}

function pickPrimary(events: NormalizedSuiUtxopiaEvent[]): NormalizedSuiUtxopiaEvent | null {
  return (
    events.find((e) => e.type === "BtcDepositVerified") ??
    events.find((e) => e.type === "JoinSplitVerified") ??
    events.find((e) => e.type === "RedemptionRequested") ??
    events.find((e) => e.type === "RedemptionCompleted") ??
    null
  );
}

// ---- field decoders (ported from web/lib/sui/explorer.ts) ----

function stringField(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "bigint") return String(value);
  if (value && typeof value === "object") {
    const r = value as Record<string, unknown>;
    if (typeof r.value === "string" || typeof r.value === "number" || typeof r.value === "bigint") return String(r.value);
    if (typeof r.fields === "object" && r.fields) return stringField((r.fields as Record<string, unknown>).value);
  }
  return undefined;
}

function bigintField(value: unknown): bigint | undefined {
  const text = stringField(value);
  if (!text) return undefined;
  try { return BigInt(text); } catch { return undefined; }
}

function numberField(value: unknown): number | undefined {
  const b = bigintField(value);
  if (b == null || b > BigInt(Number.MAX_SAFE_INTEGER)) return undefined;
  const n = Number(b);
  return Number.isFinite(n) ? n : undefined;
}

function bytesField(value: unknown, reverse = false): string | undefined {
  if (!Array.isArray(value)) return undefined;
  const bytes = value.map((x) => Number(x)).filter((x) => Number.isInteger(x) && x >= 0 && x <= 255);
  if (bytes.length !== value.length) return undefined;
  const ordered = reverse ? bytes.reverse() : bytes;
  return ordered.map((x) => x.toString(16).padStart(2, "0")).join("");
}
