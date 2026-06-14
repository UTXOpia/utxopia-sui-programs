#!/usr/bin/env bun
import { randomBytes } from "node:crypto";
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
import { fieldToSuiBytes, hexToBytes, toHex } from "./lib/bytes";
import { cleanupProof, exportSuiProof, generateProof, verifyProof } from "./test-flow/proof-artifacts";
import { readState, requireState, writeState } from "./shared";
import { executeTransactionKind } from "./signing";

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
  chainId: BigInt(process.env.UTXOPIA_SUI_CHAIN_ID ?? "784"),
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
const proofArtifacts = generateProof(CIRCUIT, circuitInputs, { tmpPrefix: "transact" });
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
