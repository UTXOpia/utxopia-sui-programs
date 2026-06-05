import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { SqliteProjections } from "../src/projections";
import type { NormalizedSuiUtxopiaEvent, SuiUtxopiaEventType } from "../src/types";

const PKG = "0xpkg";
const POOL = "0xpool";

function ev(
  type: SuiUtxopiaEventType,
  payload: Record<string, unknown>,
  digest = "d0",
  seq = "0",
): NormalizedSuiUtxopiaEvent {
  return { type, packageId: PKG, poolObjectId: POOL, cursor: { transactionDigest: digest, eventSequence: seq }, payload };
}

test("projections derive pool state, deposit notes, nullifiers, redemptions", () => {
  const proj = new SqliteProjections(new Database(":memory:"));

  proj.apply([
    ev("PoolCreated", {}),
    ev("CommitmentInserted", { leaf_index: 0, commitment: "0xaa" }, "d1"),
    ev("MerkleRootUpdated", { root: "0xroot1", root_index: 1 }, "d1"),
    ev("BtcDepositVerified", { leaf_index: 0, commitment: "0xaa", ephemeral_pubkey: "0xeph", amount_sats: "50000" }, "d1"),
    ev("NullifierSpent", { nullifier: "0xnf" }, "d2"),
    ev("RedemptionRequested", { redemption_id: 0, amount_sats: "30000", max_fee_sats: "1000", btc_script: "0x5120ab" }, "d3"),
    ev("RedemptionCompleted", { redemption_id: 0, btc_txid: "0xtxid" }, "d4"),
    ev("PoolPaused", { paused: true }, "d5"),
  ]);

  const pool = proj.getPoolState(PKG)!;
  expect(pool.paused).toBe(true);
  expect(pool.latestRoot).toBe("0xroot1");
  expect(pool.rootIndex).toBe(1);
  expect(pool.leafCount).toBe(1);

  const commitments = proj.getCommitments(PKG, 0);
  expect(commitments).toHaveLength(1);
  expect(commitments[0].leafIndex).toBe(0);
  expect(commitments[0].kind).toBe("deposit");
  expect(commitments[0].ephemeralPub).toBe("0xeph");
  expect(commitments[0].amount).toBe("50000");
  expect(commitments[0].commitment).toBe("0xaa");

  expect(proj.getCommitments(PKG, 1)).toHaveLength(0); // fromLeaf filter

  expect(proj.isNullifierSpent(PKG, "0xnf")).toBe(true);
  expect(proj.isNullifierSpent(PKG, "0xother")).toBe(false);

  const r = proj.getRedemption(PKG, 0)!;
  expect(r.status).toBe("completed");
  expect(r.amount).toBe("30000");
  expect(r.btcScript).toBe("0x5120ab");
  expect(r.btcTxid).toBe("0xtxid");
});

test("apply is idempotent on the dense leaf prefix", () => {
  const proj = new SqliteProjections(new Database(":memory:"));
  const batch = [
    ev("PoolCreated", {}),
    ev("CommitmentInserted", { leaf_index: 0, commitment: "0xaa" }, "d1"),
    ev("CommitmentInserted", { leaf_index: 1, commitment: "0xbb" }, "d2"),
  ];
  proj.apply(batch);
  proj.apply(batch); // replay must not duplicate leaves
  expect(proj.getCommitments(PKG, 0)).toHaveLength(2);
  expect(proj.getPoolState(PKG)!.leafCount).toBe(2);
});
