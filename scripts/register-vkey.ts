#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import path from "node:path";
import { UTXOpiaSuiAdapter } from "@utxopia/sdk/sui";
import { hexToBytes } from "./lib/bytes";
import { ROOT, objectRefFromChange, readState, requireState, writeState } from "./shared";
import { executeTransactionKind } from "./signing";

const circuit = process.argv[2] ?? "joinsplit_1x1";
const match = circuit.match(/^joinsplit_(\d+)x(\d+)$/);
if (!match) {
  throw new Error(`Expected circuit name like joinsplit_1x1, got ${circuit}`);
}

const nInputs = Number(match[1]);
const nOutputs = Number(match[2]);
const circuitsDir = process.env.UTXOPIA_CIRCUITS_DIR
  ? path.resolve(process.env.UTXOPIA_CIRCUITS_DIR)
  : path.resolve(ROOT, "../utxopia-circuits");
const vkeyPath = path.join(circuitsDir, "build", circuit, `${circuit}.vkey.json`);
const exportResult = spawnSync("cargo", [
  "run",
  "--quiet",
  "--manifest-path",
  path.join(ROOT, "../utxopia-circuits/sui-groth16-exporter/Cargo.toml"),
  "--",
  "vkey",
  "--input",
  vkeyPath,
], {
  cwd: ROOT,
  encoding: "utf8",
});

if (exportResult.status !== 0) {
  console.error(exportResult.stderr || exportResult.stdout);
  process.exit(exportResult.status ?? 1);
}

const exported = JSON.parse(exportResult.stdout) as {
  nPublic: number;
  rawVerifyingKey: string;
  vkHash: string;
};

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const adminCap = requireState(state.adminCap, "adminCap");
const verifyingKeyRegistry = requireState(state.verifyingKeyRegistry, "verifyingKeyRegistry");

const adapter = new UTXOpiaSuiAdapter({
  rpcUrl: process.env.UTXOPIA_SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443",
  packageId,
  poolObjectId: pool.objectId,
  poolInitialSharedVersion: pool.initialSharedVersion,
  adminCapObjectId: adminCap.objectId,
  adminCapVersion: adminCap.version,
  adminCapDigest: adminCap.digest,
  verifyingKeyRegistryObjectId: verifyingKeyRegistry.objectId,
  verifyingKeyRegistryInitialSharedVersion: verifyingKeyRegistry.initialSharedVersion,
});

const tx = await adapter.buildRegisterVerifyingKeyTransaction({
  nInputs,
  nOutputs,
  nPublic: exported.nPublic,
  vkHash: hexToBytes(exported.vkHash),
  rawVerifyingKey: hexToBytes(exported.rawVerifyingKey),
  vkGammaAbcG1Bytes: new Uint8Array(),
  alphaG1BetaG2Bytes: new Uint8Array(),
  gammaG2NegPcBytes: new Uint8Array(),
  deltaG2NegPcBytes: new Uint8Array(),
});

state.vk ??= {};
state.vk[circuit] = {
  nInputs,
  nOutputs,
  nPublic: exported.nPublic,
  vkHash: exported.vkHash,
  rawVerifyingKey: exported.rawVerifyingKey,
};

const output: Record<string, unknown> = {
  circuit,
  vkHash: exported.vkHash,
  registerPtbBytes: tx.bytes.length,
};

if (process.env.UTXOPIA_SUI_BUILD_ONLY === "1") {
  output.note = "PTB bytes built and state updated. Set UTXOPIA_SUI_BUILD_ONLY=0 or omit it to execute on-chain.";
} else {
  const result = await executeTransactionKind(tx.bytes);
  const adminChange = (result.objectChanges ?? []).find((change: any) =>
    change.objectId === adminCap.objectId && (change.type === "mutated" || change.type === "created")
  );
  state.adminCap = objectRefFromChange(adminChange) ?? state.adminCap;
  state.vk[circuit].registerTxDigest = result.digest;
  output.registerTxDigest = result.digest;
  output.status = result.effects?.status;
  output.events = result.events?.map((event) => ({
    type: event.type,
    parsedJson: event.parsedJson,
  }));
}

writeState(state);

console.log(JSON.stringify(output, null, 2));
