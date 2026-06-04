#!/usr/bin/env bun
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { sha256 } from "@noble/hashes/sha2.js";
import {
  BN254_FIELD_PRIME,
  bytesToBigint,
  computeBoundParamsHash,
  eddsaGetPubKey,
  eddsaPoseidonSign,
  poseidonHashSync,
} from "@utxopia/sdk";
import { UTXOpiaSuiAdapter } from "@utxopia/sdk/sui";
import { ROOT, readState, requireState, writeState } from "./shared";
import { executeTransactionKind } from "./signing";

const CIRCUITS_DIR = process.env.UTXOPIA_CIRCUITS_DIR
  ? path.resolve(process.env.UTXOPIA_CIRCUITS_DIR)
  : path.resolve(ROOT, "../utxopia-circuits");
const TREE_DEPTH = 16;
const ZKBTC_TOKEN_ID = 0x7a627463n;
const CIRCUIT = "joinsplit_1x1";

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const nullifierRegistry = requireState(state.nullifierRegistry, "nullifierRegistry");
const verifyingKeyRegistry = requireState(state.verifyingKeyRegistry, "verifyingKeyRegistry");
const vk = requireState(state.vk?.[CIRCUIT], `${CIRCUIT} vk`);

const seed = randomBytes(32);
const publicKey = await eddsaGetPubKey(seed);
const nullifyingKey = randomFieldElement();
const mpk = poseidonHashSync([publicKey.x, publicKey.y, nullifyingKey]);

const amount = BigInt(process.env.UTXOPIA_SUI_POC_AMOUNT_SATS ?? "1");
const inputRandom = randomFieldElement();
const inputNpk = poseidonHashSync([mpk, inputRandom]);
const inputCommitment = poseidonHashSync([inputNpk, ZKBTC_TOKEN_ID, amount]);

const merkle = buildSingleLeafProof(inputCommitment);
const outputRandom = randomFieldElement();
const outputNpk = poseidonHashSync([mpk, outputRandom]);
const outputCommitment = poseidonHashSync([outputNpk, ZKBTC_TOKEN_ID, amount]);
const nullifier = poseidonHashSync([nullifyingKey, 0n]);
const boundParamsHash = computeBoundParamsHash({
  treeNumber: 0,
  unshieldAddress: null,
  chainId: BigInt(process.env.UTXOPIA_SUI_CHAIN_ID ?? "103"),
  stealthDataHash: sha256(new Uint8Array()),
});
const msgHash = poseidonHashSync([merkle.root, boundParamsHash, nullifier, outputCommitment]);
const signature = await eddsaPoseidonSign(seed, msgHash);

const circuitInputs = {
  merkleRoot: merkle.root.toString(),
  boundParamsHash: boundParamsHash.toString(),
  nullifiers: [nullifier.toString()],
  commitmentsOut: [outputCommitment.toString()],
  token: ZKBTC_TOKEN_ID.toString(),
  publicKey: [publicKey.x.toString(), publicKey.y.toString()],
  signature: signature.map((item) => item.toString()),
  nullifyingKey: nullifyingKey.toString(),
  randomIn: [inputRandom.toString()],
  valueIn: [amount.toString()],
  leavesIndices: ["0"],
  pathElements: [merkle.siblings.map((item) => item.toString())],
  pathIndices: [merkle.indices],
  npkOut: [outputNpk.toString()],
  valueOut: [amount.toString()],
};

console.log(`Generating ${CIRCUIT} Groth16 proof...`);
const proofArtifacts = generateProof(CIRCUIT, circuitInputs);
console.log("Verifying generated proof with snarkjs...");
verifyProof(CIRCUIT, proofArtifacts.proofPath, proofArtifacts.publicPath);
console.log("Exporting proof to Sui native Groth16 bytes...");
const exportedProof = exportSuiProof(proofArtifacts.proofPath, proofArtifacts.publicPath);

const publicInputs = hexToBytes(exportedProof.publicInputs);
const proofPoints = hexToBytes(exportedProof.proofPoints);
const nullifierBytes = publicInputs.slice(64, 96);
const commitmentOutBytes = publicInputs.slice(96, 128);

const adapter = new UTXOpiaSuiAdapter({
  rpcUrl: process.env.UTXOPIA_SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443",
  packageId,
  poolObjectId: pool.objectId,
  poolInitialSharedVersion: pool.initialSharedVersion,
  nullifierRegistryObjectId: nullifierRegistry.objectId,
  nullifierRegistryInitialSharedVersion: nullifierRegistry.initialSharedVersion,
  verifyingKeyRegistryObjectId: verifyingKeyRegistry.objectId,
  verifyingKeyRegistryInitialSharedVersion: verifyingKeyRegistry.initialSharedVersion,
});

const tx = await adapter.buildTransactTransaction({
  inputNotes: [{
    commitment: toHex(fieldToSuiBytes(inputCommitment)),
    nullifier: toHex(nullifierBytes),
    tokenId: "zkbtc",
    leafIndex: 0,
  }],
  outputs: [{
    recipient: "sui-poc",
    tokenId: "zkbtc",
    amount,
  }],
  proof: proofPoints,
  boundParamsHash: toHex(fieldToSuiBytes(boundParamsHash)),
  vkHash: hexToBytes(vk.vkHash),
  publicInputs,
  proofPoints,
  commitmentsOut: [commitmentOutBytes],
});

console.log("Submitting Sui transact transaction...");
const result = await executeTransactionKind(tx.bytes);
state.lastTransact = {
  circuit: CIRCUIT,
  txDigest: result.digest,
  nullifier: toHex(nullifierBytes),
  commitmentOut: toHex(commitmentOutBytes),
  proofPublicInputs: exportedProof.publicInputs,
};
writeState(state);

console.log(JSON.stringify({
  circuit: CIRCUIT,
  txDigest: result.digest,
  status: result.effects?.status,
  vkHash: vk.vkHash,
  nullifier: toHex(nullifierBytes),
  commitmentOut: toHex(commitmentOutBytes),
  proofPointsBytes: proofPoints.length,
  publicInputBytes: publicInputs.length,
  events: result.events?.map((event) => ({
    type: event.type,
    parsedJson: event.parsedJson,
  })) ?? [],
}, null, 2));

cleanupProof(proofArtifacts.tmpDir);

function buildSingleLeafProof(leaf: bigint) {
  const zeroHashes = computeZeroHashes();
  const siblings = zeroHashes.slice(0, TREE_DEPTH);
  const indices = new Array(TREE_DEPTH).fill(0);
  let root = leaf;
  for (let level = 0; level < TREE_DEPTH; level += 1) {
    root = poseidonHashSync([root, zeroHashes[level]]);
  }
  return { root, siblings, indices };
}

function computeZeroHashes(): bigint[] {
  const zeroHashes = [0n];
  for (let i = 1; i <= TREE_DEPTH; i += 1) {
    zeroHashes[i] = poseidonHashSync([zeroHashes[i - 1], zeroHashes[i - 1]]);
  }
  return zeroHashes;
}

function randomFieldElement(): bigint {
  return bytesToBigint(randomBytes(32)) % BN254_FIELD_PRIME;
}

function generateProof(circuit: string, inputs: Record<string, unknown>) {
  const circuitDir = path.join(CIRCUITS_DIR, "build", circuit);
  const wasmPath = path.join(circuitDir, `${circuit}_js`, `${circuit}.wasm`);
  const zkeyPath = path.join(circuitDir, `${circuit}.zkey`);
  if (!existsSync(wasmPath)) {
    throw new Error(`Missing circuit WASM: ${wasmPath}`);
  }
  if (!existsSync(zkeyPath)) {
    throw new Error(`Missing circuit zkey: ${zkeyPath}`);
  }

  const tmpDir = path.join(ROOT, ".tmp", `transact-${Date.now()}`);
  mkdirSync(tmpDir, { recursive: true });
  const inputPath = path.join(tmpDir, "input.json");
  const proofPath = path.join(tmpDir, "proof.json");
  const publicPath = path.join(tmpDir, "public.json");
  const runnerPath = path.join(tmpDir, "prove.cjs");
  writeFileSync(inputPath, JSON.stringify(inputs));
  writeFileSync(runnerPath, `
const fs = require("fs");
const snarkjs = require("snarkjs");
(async () => {
  const input = JSON.parse(fs.readFileSync(${JSON.stringify(inputPath)}, "utf8"));
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    ${JSON.stringify(wasmPath)},
    ${JSON.stringify(zkeyPath)}
  );
  fs.writeFileSync(${JSON.stringify(proofPath)}, JSON.stringify(proof));
  fs.writeFileSync(${JSON.stringify(publicPath)}, JSON.stringify(publicSignals));
  process.exit(0);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
`);

  execFileSync("node", [runnerPath], {
    cwd: ROOT,
    stdio: "inherit",
    timeout: Number(process.env.UTXOPIA_SUI_PROVE_TIMEOUT_MS ?? "300000"),
  });
  return { tmpDir, proofPath, publicPath };
}

function verifyProof(circuit: string, proofPath: string, publicPath: string) {
  const vkeyPath = path.join(CIRCUITS_DIR, "build", circuit, `${circuit}.vkey.json`);
  const runnerPath = path.join(path.dirname(proofPath), "verify.cjs");
  writeFileSync(runnerPath, `
const fs = require("fs");
const snarkjs = require("snarkjs");
(async () => {
  const vkey = JSON.parse(fs.readFileSync(${JSON.stringify(vkeyPath)}, "utf8"));
  const proof = JSON.parse(fs.readFileSync(${JSON.stringify(proofPath)}, "utf8"));
  const publicSignals = JSON.parse(fs.readFileSync(${JSON.stringify(publicPath)}, "utf8"));
  const ok = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  if (!ok) throw new Error("snarkjs rejected generated proof");
  process.exit(0);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
`);
  execFileSync("node", [runnerPath], {
    cwd: ROOT,
    stdio: "inherit",
    timeout: Number(process.env.UTXOPIA_SUI_PROVE_TIMEOUT_MS ?? "300000"),
  });
}

function exportSuiProof(proofPath: string, publicPath: string): {
  proofPoints: string;
  publicInputs: string;
} {
  const result = spawnSync("cargo", [
    "run",
    "--quiet",
    "--manifest-path",
    path.join(ROOT, "../utxopia-circuits/sui-groth16-exporter/Cargo.toml"),
    "--",
    "proof",
    "--proof",
    proofPath,
    "--public",
    publicPath,
  ], {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout);
  }
  return JSON.parse(result.stdout);
}

function fieldToSuiBytes(value: bigint): Uint8Array {
  const bytes = new Uint8Array(32);
  let n = value;
  for (let i = 0; i < 32; i += 1) {
    bytes[i] = Number(n & 0xffn);
    n >>= 8n;
  }
  return bytes;
}

function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function cleanupProof(tmpDir: string) {
  if (process.env.UTXOPIA_SUI_KEEP_PROOF_TMP === "1") {
    return;
  }
  rmSync(tmpDir, { recursive: true, force: true });
}
