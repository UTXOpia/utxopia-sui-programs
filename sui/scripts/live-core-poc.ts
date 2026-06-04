#!/usr/bin/env bun
import { UTXOpiaSuiAdapter } from "../../../packages/sdk-sui/src/sui-adapter";
import { readState, requireState, writeState } from "./shared";
import { executeTransactionKind } from "./signing";

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const nullifierRegistry = requireState(state.nullifierRegistry, "nullifierRegistry");
const redemptionQueue = requireState(state.redemptionQueue, "redemptionQueue");
const redemptionCap = requireState(state.redemptionCap, "redemptionCap");
const verifyingKeyRegistry = requireState(state.verifyingKeyRegistry, "verifyingKeyRegistry");

const adapter = new UTXOpiaSuiAdapter({
  rpcUrl: process.env.UTXOPIA_SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443",
  packageId,
  poolObjectId: pool.objectId,
  poolInitialSharedVersion: pool.initialSharedVersion,
  nullifierRegistryObjectId: nullifierRegistry.objectId,
  nullifierRegistryInitialSharedVersion: nullifierRegistry.initialSharedVersion,
  redemptionQueueObjectId: redemptionQueue.objectId,
  redemptionQueueInitialSharedVersion: redemptionQueue.initialSharedVersion,
  redemptionCapObjectId: redemptionCap.objectId,
  redemptionCapVersion: redemptionCap.version,
  redemptionCapDigest: redemptionCap.digest,
  verifyingKeyRegistryObjectId: verifyingKeyRegistry.objectId,
  verifyingKeyRegistryInitialSharedVersion: verifyingKeyRegistry.initialSharedVersion,
});

const requestTx = await adapter.buildRedemptionTransaction({
  inputNotes: [],
  btcAddress: "00".repeat(32),
  amountSats: BigInt(process.env.UTXOPIA_SUI_POC_AMOUNT_SATS ?? "1"),
  maxFeeSats: BigInt(process.env.UTXOPIA_SUI_POC_MAX_FEE_SATS ?? "1"),
  proof: new Uint8Array(),
});
const requestResult = await executeTransactionKind(requestTx.bytes);
const redemptionId = findEventField(requestResult.events, "RedemptionRequested", "redemption_id");
if (redemptionId === undefined) {
  throw new Error(`RedemptionRequested event missing from ${requestResult.digest}`);
}

const approveTx = await adapter.buildIkaApprovalTransaction({
  redemptionId: BigInt(redemptionId),
  sighash: new Uint8Array(32).fill(9),
});
const approveResult = await executeTransactionKind(approveTx.bytes);

const completeTx = await adapter.buildCompleteRedemptionTransaction({
  redemptionId: BigInt(redemptionId),
  btcTxid: new Uint8Array(32).fill(10),
});
const completeResult = await executeTransactionKind(completeTx.bytes);

state.lastRedemption = {
  redemptionId: String(redemptionId),
  requestTxDigest: requestResult.digest,
  ikaApprovalTxDigest: approveResult.digest,
  completeTxDigest: completeResult.digest,
};
writeState(state);

console.log(JSON.stringify({
  redemptionId: String(redemptionId),
  requestTxDigest: requestResult.digest,
  requestStatus: requestResult.effects?.status,
  ikaApprovalTxDigest: approveResult.digest,
  ikaApprovalStatus: approveResult.effects?.status,
  completeTxDigest: completeResult.digest,
  completeStatus: completeResult.effects?.status,
  events: {
    request: summarizeEvents(requestResult.events),
    ikaApproval: summarizeEvents(approveResult.events),
    complete: summarizeEvents(completeResult.events),
  },
}, null, 2));

function findEventField(events: any[] | undefined, typeSuffix: string, field: string): string | undefined {
  const event = events?.find((candidate) => typeof candidate.type === "string" && candidate.type.endsWith(typeSuffix));
  const value = event?.parsedJson?.[field];
  return value === undefined ? undefined : String(value);
}

function summarizeEvents(events: any[] | undefined) {
  return events?.map((event) => ({
    type: event.type,
    parsedJson: event.parsedJson,
  })) ?? [];
}
