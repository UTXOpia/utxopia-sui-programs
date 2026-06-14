import { expect, test } from "bun:test";
import { buildExplorerStats, buildExplorerTransactions } from "../src/explorer-projection";
import type { NormalizedSuiUtxopiaEvent, SuiUtxopiaEventType } from "../src/types";

const PKG = "0x916737cd";
const POOL = "0xpool";

function ev(
  type: SuiUtxopiaEventType,
  txDigest: string,
  eventSeq: string,
  payload: Record<string, unknown>,
  timestampMs = "1000",
): NormalizedSuiUtxopiaEvent {
  return {
    type,
    packageId: PKG,
    poolObjectId: POOL,
    cursor: { transactionDigest: txDigest, eventSequence: eventSeq },
    timestampMs,
    payload,
  };
}

const bytes = (n: number, b: number) => Array.from({ length: n }, () => b);

test("shield tx from BtcDepositVerified", () => {
  const events = [
    ev("BtcDepositVerified", "txDep", "0", {
      commitment: bytes(32, 0x11),
      leaf_index: "0",
      amount_sats: "25000",
      deposit_txid: bytes(32, 0xaa),
      ephemeral_pubkey: bytes(32, 0xbb),
    }, "5000"),
  ];
  const txs = buildExplorerTransactions(events, { poolAddress: "bcrt1ppool" });
  expect(txs).toHaveLength(1);
  expect(txs[0]!.type).toBe("shield");
  expect(txs[0]!.timestamp).toBe(5000);
  expect((txs[0]!.btcMeta as Record<string, unknown>).taprootAddress).toBe("bcrt1ppool");
  expect((txs[0]!.outputs[0] as Record<string, unknown>).amount).toBe(25000);
});

test("transfer tx groups JoinSplit + nullifiers + commitments", () => {
  const events = [
    ev("JoinSplitVerified", "txT", "0", {}),
    ev("NullifierSpent", "txT", "1", { nullifier: bytes(32, 0x01) }),
    ev("CommitmentInserted", "txT", "2", { commitment: bytes(32, 0x02), leaf_index: "1" }),
  ];
  const txs = buildExplorerTransactions(events);
  expect(txs).toHaveLength(1);
  expect(txs[0]!.type).toBe("transfer");
  expect(txs[0]!.inputs).toHaveLength(1);
  expect(txs[0]!.outputs).toHaveLength(1);
});

test("withdraw tx pairs request + completion across txs", () => {
  const events = [
    ev("RedemptionRequested", "txReq", "0", {
      redemption_id: "4", amount_sats: "15000", max_fee_sats: "1000", btc_script: bytes(34, 0x51),
    }, "2000"),
    ev("RedemptionCompleted", "txComp", "0", {
      redemption_id: "4", btc_txid: bytes(32, 0xcc),
    }, "3000"),
  ];
  const txs = buildExplorerTransactions(events);
  expect(txs).toHaveLength(1);
  expect(txs[0]!.type).toBe("withdraw");
  expect(txs[0]!.status).toBe("confirmed");
  expect(txs[0]!.timestamp).toBe(3000);
  const out = txs[0]!.outputs[0] as Record<string, unknown>;
  expect(out.payout).toBe(14000); // 15000 - 1000
  expect(out.localStatus).toBe("Completed");
});

test("stats: shielded minus redeemed, commitment count", () => {
  const events = [
    ev("BtcDepositVerified", "t1", "0", { commitment: bytes(32, 0x11), leaf_index: "0", amount_sats: "25000" }),
    ev("CommitmentInserted", "t1", "1", { commitment: bytes(32, 0x11), leaf_index: "0" }),
    ev("CommitmentInserted", "t2", "0", { commitment: bytes(32, 0x22), leaf_index: "1" }),
    ev("RedemptionRequested", "t3", "0", { redemption_id: "1", amount_sats: "5000", max_fee_sats: "100", btc_script: bytes(34, 0x51) }),
  ];
  const stats = buildExplorerStats(events);
  expect(stats.depositCount).toBe(1);
  expect(stats.totalShielded).toBe("20000"); // 25000 - 5000
  expect(stats.volume).toBe("30000"); // 25000 + 5000
  expect(stats.totalCommitments).toBe(2);
});

test("descending by timestamp", () => {
  const events = [
    ev("BtcDepositVerified", "a", "0", { commitment: bytes(32, 1), leaf_index: "0", amount_sats: "1" }, "100"),
    ev("BtcDepositVerified", "b", "0", { commitment: bytes(32, 2), leaf_index: "1", amount_sats: "1" }, "300"),
  ];
  const txs = buildExplorerTransactions(events);
  expect(txs.map((t) => t.timestamp)).toEqual([300, 100]);
});
