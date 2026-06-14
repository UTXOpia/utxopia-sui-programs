#!/usr/bin/env bun
// Standalone BTC light-client bootstrap for the current deployment, anchored at the
// local regtest tip (network byte 3). Mirrors regtest-flow.ts ensureLightClientInitialized,
// then binds pool.light_client_id. Idempotent: skips if state.lightClient already set.
import { Transaction } from "@mysten/sui/transactions";
import {
  readState,
  requireState,
  writeState,
  findCreatedObject,
  objectRefFromChange,
  sharedRefFromChange,
} from "./shared";
import { bitcoinCli } from "./lib/regtest-helpers";
import { executeBuiltTransaction } from "./signing";

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const adminCap = requireState(state.adminCap, "adminCap");

if (state.lightClient) {
  console.log(JSON.stringify({ skipped: true, reason: "state.lightClient already set", lightClient: state.lightClient }, null, 2));
  process.exit(0);
}

const tipHeight = Number(bitcoinCli("getblockcount").trim());
const anchorHash = bitcoinCli(`getblockhash ${tipHeight}`).trim();
const anchorRawHeader = Uint8Array.from(Buffer.from(bitcoinCli(`getblockheader ${anchorHash} false`).trim(), "hex"));
const anchor = JSON.parse(bitcoinCli(`getblock ${anchorHash} 1`));
console.log(`Initializing BTC light client anchored at regtest block ${tipHeight} (${anchorHash})...`);

const initTx = new Transaction();
initTx.moveCall({
  target: `${packageId}::btc_light_client::initialize`,
  arguments: [
    initTx.pure.u8(3), // NETWORK_REGTEST
    initTx.pure.vector("u8", Array.from(anchorRawHeader)),
    initTx.pure.u64(BigInt(anchor.height)),
    initTx.pure.u256(BigInt(`0x${anchor.chainwork}`)),
    initTx.pure.u32(Number.parseInt(anchor.bits, 16)),
    initTx.pure.u32(Number(anchor.time)),
  ],
});
const initResult = await executeBuiltTransaction(initTx);
if (initResult.effects?.status?.status !== "success") {
  throw new Error(`light-client init failed: ${JSON.stringify(initResult.effects?.status)}`);
}
const changes = initResult.objectChanges ?? [];
state.lightClient = sharedRefFromChange(findCreatedObject(changes, "::btc_light_client::LightClient"));
state.lightClientAdminCap = objectRefFromChange(findCreatedObject(changes, "::btc_light_client::LightClientAdminCap"));
writeState(state);
console.log(`light client = ${state.lightClient?.objectId}`);

// Bind pool.light_client_id (one-shot).
const bindTx = new Transaction();
bindTx.moveCall({
  target: `${packageId}::pool::set_light_client_id`,
  arguments: [
    bindTx.object(adminCap.objectId),
    bindTx.sharedObjectRef({ objectId: pool.objectId, initialSharedVersion: pool.initialSharedVersion, mutable: true }),
    bindTx.pure.address(state.lightClient!.objectId),
  ],
});
const bindResult = await executeBuiltTransaction(bindTx);
if (bindResult.effects?.status?.status !== "success") {
  throw new Error(`pool light-client bind failed: ${JSON.stringify(bindResult.effects?.status)}`);
}

console.log(JSON.stringify({
  lightClient: state.lightClient,
  lightClientAdminCap: state.lightClientAdminCap,
  boundToPool: pool.objectId,
  anchorHeight: tipHeight,
  initDigest: initResult.digest,
  bindDigest: bindResult.digest,
}, null, 2));
