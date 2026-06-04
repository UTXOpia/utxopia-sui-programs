#!/usr/bin/env bun
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes, createHash } from "node:crypto";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { sha256 } from "@noble/hashes/sha2.js";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Curve, SignatureAlgorithm } from "@ika.xyz/sdk";
import {
  BN254_FIELD_PRIME,
  bytesToBigint,
  computeBoundParamsHash,
  eddsaGetPubKey,
  eddsaPoseidonSign,
  poseidonHashSync,
} from "@utxopia/sdk";
import { UTXOpiaSuiAdapter } from "@utxopia/sdk/sui";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";
import {
  createOpReturnTx,
  getNewAddress,
  mineBlocks,
  waitForEsplora,
  waitForTxIndexed,
  bitcoinCli,
} from "./lib/regtest-helpers";
import { ROOT, readState, requireState, writeState } from "./shared";
import { executeTransactionKind } from "./signing";
import { loadOrCreateIkaUserShareKeys } from "./ika-user-share-keys";

const CIRCUITS_DIR = process.env.UTXOPIA_CIRCUITS_DIR
  ? path.resolve(process.env.UTXOPIA_CIRCUITS_DIR)
  : path.resolve(ROOT, "../utxopia-circuits");
const ESPLORA_URL = process.env.ESPLORA_URL ?? "http://localhost:3002/regtest/api";
const TREE_DEPTH = 16;
const ZKBTC_TOKEN_ID = 0x7a627463n;
const CIRCUIT = "joinsplit_1x1";

const state = readState();
const SUI_RPC_URL = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const verifiedDeposit = requireState(state.lastVerifiedBtcDeposit, "lastVerifiedBtcDeposit");
const btcDepositRegistry = requireState(state.btcDepositRegistry, "btcDepositRegistry");
const nullifierRegistry = requireState(state.nullifierRegistry, "nullifierRegistry");
const redemptionQueue = requireState(state.redemptionQueue, "redemptionQueue");
const redemptionCap = requireState(state.redemptionCap, "redemptionCap");
const verifyingKeyRegistry = requireState(state.verifyingKeyRegistry, "verifyingKeyRegistry");
const vk = requireState(state.vk?.[CIRCUIT], `${CIRCUIT} vk`);

const amount = BigInt(process.env.UTXOPIA_SUI_REGTEST_AMOUNT_SATS ?? "25000");
const minerFee = BigInt(process.env.UTXOPIA_SUI_REGTEST_WITHDRAW_FEE_SATS ?? "1000");
const withdrawalSignerMode = process.env.UTXOPIA_SUI_WITHDRAW_SIGNER_MODE ?? "relayer";
if (amount <= minerFee + 546n) {
  throw new Error("UTXOPIA_SUI_REGTEST_AMOUNT_SATS must exceed fee plus dust threshold");
}
if (withdrawalSignerMode !== "relayer" && withdrawalSignerMode !== "ika") {
  throw new Error("UTXOPIA_SUI_WITHDRAW_SIGNER_MODE must be `relayer` or `ika`");
}
const ikaSigningConfig = withdrawalSignerMode === "ika" ? requireIkaSuiSigningConfig() : null;

let adapter = createAdapter(redemptionCap);

function createAdapter(cap: typeof redemptionCap) {
  return new UTXOpiaSuiAdapter({
    rpcUrl: SUI_RPC_URL,
    packageId,
    poolObjectId: pool.objectId,
    poolInitialSharedVersion: pool.initialSharedVersion,
    btcDepositRegistryObjectId: btcDepositRegistry.objectId,
    btcDepositRegistryInitialSharedVersion: btcDepositRegistry.initialSharedVersion,
    nullifierRegistryObjectId: nullifierRegistry.objectId,
    nullifierRegistryInitialSharedVersion: nullifierRegistry.initialSharedVersion,
    redemptionQueueObjectId: redemptionQueue.objectId,
    redemptionQueueInitialSharedVersion: redemptionQueue.initialSharedVersion,
    redemptionCapObjectId: redemptionCap.objectId,
    redemptionCapVersion: cap.version,
    redemptionCapDigest: cap.digest,
    verifyingKeyRegistryObjectId: verifyingKeyRegistry.objectId,
    verifyingKeyRegistryInitialSharedVersion: verifyingKeyRegistry.initialSharedVersion,
  });
}

await waitForEsplora(ESPLORA_URL, 30_000);

const note = await buildJoinSplitNote(amount);
const deposit = await createDirectDeposit(note.inputNpk, amount);
await assertVerifiedDepositMatches({
  objectId: verifiedDeposit.objectId,
  depositTxid: reverseHexToBytes(deposit.depositTxid),
  depositVout: deposit.depositVout,
  amountSats: amount,
  opReturnPayload: deposit.opReturnPayload,
  commitment: fieldToSuiBytes(note.inputCommitment),
  verifiedRoot: fieldToSuiBytes(note.merkle.root),
});

console.log("Submitting Sui verified BTC deposit...");
const shieldTx = await adapter.buildBtcDepositTransaction({
  verifiedDepositObjectId: verifiedDeposit.objectId,
  verifiedDepositVersion: verifiedDeposit.version,
  verifiedDepositDigest: verifiedDeposit.digest,
});
const shieldResult = await executeTransactionKind(shieldTx.bytes);
assertSuiSuccess("shield", shieldResult);

console.log("Submitting Sui private transfer proof...");
const transactTx = await adapter.buildTransactTransaction({
  inputNotes: [{
    commitment: toHex(fieldToSuiBytes(note.inputCommitment)),
    nullifier: toHex(note.nullifierBytes),
    tokenId: "zkbtc",
    leafIndex: 0,
  }],
  outputs: [{
    recipient: "sui-regtest",
    tokenId: "zkbtc",
    amount,
  }],
  proof: note.proofPoints,
  boundParamsHash: toHex(fieldToSuiBytes(note.boundParamsHash)),
  vkHash: hexToBytes(vk.vkHash),
  publicInputs: note.publicInputs,
  proofPoints: note.proofPoints,
  commitmentsOut: [note.commitmentOutBytes],
});
const transactResult = await executeTransactionKind(transactTx.bytes);
assertSuiSuccess("transact", transactResult);

const withdrawal = await broadcastWithdrawal(deposit.depositTxid, deposit.depositVout, deposit.amountSats, amount - minerFee);

console.log("Submitting Sui redemption request...");
const requestTx = await adapter.buildRedemptionTransaction({
  inputNotes: [],
  btcAddress: toHex(createHash("sha256").update(withdrawal.destinationAddress).digest()),
  amountSats: amount,
  maxFeeSats: minerFee,
  proof: new Uint8Array(),
});
const requestResult = await executeTransactionKind(requestTx.bytes);
assertSuiSuccess("request redemption", requestResult);
const redemptionId = findEventField(requestResult.events, "RedemptionRequested", "redemption_id");
if (redemptionId === undefined) {
  throw new Error(`RedemptionRequested event missing from ${requestResult.digest}`);
}

let approveResult: Awaited<ReturnType<typeof executeTransactionKind>> | null = null;
let ikaSigningResult: Awaited<ReturnType<typeof submitNativeIkaSigning>> | null = null;
if (withdrawalSignerMode === "ika") {
  console.log("Submitting Sui Ika policy approval...");
  const withdrawalSighash = createHash("sha256").update(withdrawal.rawTxHex).digest();
  const approveTx = await adapter.buildIkaApprovalTransaction({
    redemptionId: BigInt(redemptionId),
    sighash: withdrawalSighash,
  });
  approveResult = await executeTransactionKind(approveTx.bytes);
  assertSuiSuccess("Ika policy approval", approveResult);
  ikaSigningResult = await submitNativeIkaSigning(withdrawalSighash, ikaSigningConfig!);
} else {
  console.log("Skipping Sui Ika policy approval; regtest withdrawal uses the local relayer signer.");
}

console.log("Submitting Sui redemption completion...");
const freshRedemptionCap = await refreshObjectRef(redemptionCap.objectId);
state.redemptionCap = freshRedemptionCap;
adapter = createAdapter(freshRedemptionCap);
const completeTx = await adapter.buildCompleteRedemptionTransaction({
  redemptionId: BigInt(redemptionId),
  btcTxid: reverseHexToBytes(withdrawal.withdrawTxid),
});
const completeResult = await executeTransactionKind(completeTx.bytes);
assertSuiSuccess("complete redemption", completeResult);

(state as any).lastSuiRegtestFlow = {
  amountSats: amount.toString(),
  depositTxid: deposit.depositTxid,
  shieldTxDigest: shieldResult.digest,
  transactTxDigest: transactResult.digest,
  withdrawTxid: withdrawal.withdrawTxid,
  withdrawalSignerMode,
  redemptionId: String(redemptionId),
  requestTxDigest: requestResult.digest,
  ...(approveResult ? { ikaApprovalTxDigest: approveResult.digest } : {}),
  ...(ikaSigningResult ? { ikaSigning: ikaSigningResult } : {}),
  completeTxDigest: completeResult.digest,
};
writeState(state);

console.log(JSON.stringify({
  amountSats: amount.toString(),
  btc: {
    depositTxid: deposit.depositTxid,
    depositVout: deposit.depositVout,
    depositAmountSats: deposit.amountSats.toString(),
    poolAddress: deposit.poolAddress,
    withdrawTxid: withdrawal.withdrawTxid,
    destinationAddress: withdrawal.destinationAddress,
  },
  sui: {
    shieldTxDigest: shieldResult.digest,
    shieldStatus: shieldResult.effects?.status,
    transactTxDigest: transactResult.digest,
    transactStatus: transactResult.effects?.status,
    redemptionId: String(redemptionId),
    requestTxDigest: requestResult.digest,
    requestStatus: requestResult.effects?.status,
    withdrawalSignerMode,
    ...(approveResult ? {
      ikaApprovalTxDigest: approveResult.digest,
      ikaApprovalStatus: approveResult.effects?.status,
    } : {}),
    ...(ikaSigningResult ? { ikaSigning: ikaSigningResult } : {}),
    completeTxDigest: completeResult.digest,
    completeStatus: completeResult.effects?.status,
  },
  limitations: [
    "Sui BTC deposit now consumes btc_light_client::VerifiedBtcDeposit before btc_deposit::complete_verified_deposit; create this object with the production Sui SPV verifier before running the flow.",
    withdrawalSignerMode === "ika"
      ? "Native Sui Ika policy approval, global Taproot presign, and Taproot sign request are executed; this regtest BTC broadcast still uses the local regtest wallet because the PoC deposit UTXO is created under the local regtest pool address."
      : "BTC withdrawal is signed by the local regtest relayer wallet; native Sui Ika dWallet signing remains optional for later testnet work.",
  ],
}, null, 2));

cleanupProof(note.tmpDir);

async function createDirectDeposit(inputNpk: bigint, depositAmount: bigint) {
  console.log("Creating direct regtest BTC deposit to pool with OP_RETURN(ephemeralPub || npk)...");
  const ephPub = randomBytes(32);
  const payloadHex = ephPub.toString("hex") + Buffer.from(fieldToSuiBytes(inputNpk)).toString("hex");
  const poolAddress = process.env.UTXOPIA_SUI_REGTEST_POOL_BTC_ADDRESS ?? getNewAddress("bech32m");
  const depositTxid = createOpReturnTx(poolAddress, Number(depositAmount), payloadHex);
  const minerAddress = getNewAddress("bech32m");
  mineBlocks(6, minerAddress);
  await waitForTxIndexed(depositTxid, ESPLORA_URL);

  const depositTx = JSON.parse(btc(`gettransaction ${depositTxid} true true`));
  const decoded = depositTx.decoded ?? JSON.parse(btc(`decoderawtransaction ${depositTx.hex}`));
  const depositOutput = decoded.vout.find((out: any) => out.scriptPubKey?.address === poolAddress);
  if (!depositOutput) {
    throw new Error("Could not find direct pool deposit output");
  }
  const outputAmountSats = BigInt(Math.round(Number(depositOutput.value) * 1e8));
  if (outputAmountSats !== depositAmount) {
    throw new Error(`Deposit output amount ${outputAmountSats} does not match note amount ${depositAmount}`);
  }

  return {
    depositTxid,
    depositVout: Number(depositOutput.n),
    amountSats: outputAmountSats,
    poolAddress,
    opReturnPayload: hexToBytes(payloadHex),
  };
}

async function broadcastWithdrawal(depositTxid: string, depositVout: number, inputAmountSats: bigint, sendAmountSats: bigint) {
  console.log("Broadcasting regtest BTC withdrawal from direct pool deposit UTXO with the local relayer signer...");
  const destinationAddress = process.env.UTXOPIA_SUI_REGTEST_WITHDRAW_BTC_ADDRESS ?? getNewAddress("bech32m");
  const poolChangeAddress = process.env.UTXOPIA_SUI_REGTEST_POOL_BTC_ADDRESS ?? getNewAddress("bech32m");
  const changeSats = inputAmountSats - sendAmountSats - minerFee;
  if (sendAmountSats <= 546n) {
    throw new Error(`Withdrawal output ${sendAmountSats} sats is dust`);
  }
  if (changeSats < 0n) {
    throw new Error("Withdrawal amount plus fee exceeds swept input amount");
  }

  const outputs: Record<string, number> = {
    [destinationAddress]: Number(sendAmountSats) / 1e8,
  };
  if (changeSats > 546n) {
    outputs[poolChangeAddress] = Number(changeSats) / 1e8;
  }

  const rawTxHex = btc(`-named createrawtransaction inputs='[{"txid":"${depositTxid}","vout":${depositVout}}]' outputs='${JSON.stringify(outputs)}'`);
  const signed = JSON.parse(btc(`signrawtransactionwithwallet ${rawTxHex}`));
  if (!signed.complete) {
    throw new Error("Failed to sign withdrawal transaction");
  }
  const withdrawTxid = btc(`sendrawtransaction ${signed.hex}`);
  mineBlocks(6);
  await waitForTxIndexed(withdrawTxid, ESPLORA_URL);

  return {
    destinationAddress,
    withdrawTxid,
    rawTxHex: signed.hex as string,
  };
}

async function buildJoinSplitNote(noteAmount: bigint) {
  const seed = randomBytes(32);
  const publicKey = await eddsaGetPubKey(seed);
  const nullifyingKey = randomFieldElement();
  const mpk = poseidonHashSync([publicKey.x, publicKey.y, nullifyingKey]);
  const inputRandom = randomFieldElement();
  const inputNpk = poseidonHashSync([mpk, inputRandom]);
  const inputCommitment = poseidonHashSync([inputNpk, ZKBTC_TOKEN_ID, noteAmount]);
  const merkle = buildSingleLeafProof(inputCommitment);
  const outputRandom = randomFieldElement();
  const outputNpk = poseidonHashSync([mpk, outputRandom]);
  const outputCommitment = poseidonHashSync([outputNpk, ZKBTC_TOKEN_ID, noteAmount]);
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
    valueIn: [noteAmount.toString()],
    leavesIndices: ["0"],
    pathElements: [merkle.siblings.map((item) => item.toString())],
    pathIndices: [merkle.indices],
    npkOut: [outputNpk.toString()],
    valueOut: [noteAmount.toString()],
  };

  console.log(`Generating ${CIRCUIT} Groth16 proof...`);
  const proofArtifacts = generateProof(CIRCUIT, circuitInputs);
  console.log("Verifying generated proof with snarkjs...");
  verifyProof(CIRCUIT, proofArtifacts.proofPath, proofArtifacts.publicPath);
  console.log("Exporting proof to Sui native Groth16 bytes...");
  const exportedProof = exportSuiProof(proofArtifacts.proofPath, proofArtifacts.publicPath);

  const publicInputs = hexToBytes(exportedProof.publicInputs);
  return {
    ...proofArtifacts,
    inputNpk,
    inputCommitment,
    outputCommitment,
    merkle,
    boundParamsHash,
    publicInputs,
    proofPoints: hexToBytes(exportedProof.proofPoints),
    nullifierBytes: publicInputs.slice(64, 96),
    commitmentOutBytes: publicInputs.slice(96, 128),
  };
}

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

  const tmpDir = path.join(ROOT, ".tmp", `regtest-flow-${Date.now()}`);
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
    stdio: ["ignore", "pipe", "pipe"],
    timeout: Number(process.env.UTXOPIA_SUI_EXPORT_TIMEOUT_MS ?? "300000"),
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to export Sui Groth16 proof");
  }

  const parsed = JSON.parse(result.stdout.trim()) as { proofPoints: string; publicInputs: string };
  return parsed;
}

function cleanupProof(tmpDir: string) {
  if (process.env.UTXOPIA_SUI_KEEP_PROOF_TMP === "1") {
    return;
  }
  rmSync(tmpDir, { recursive: true, force: true });
}

function hexToBytes(hex: string): Uint8Array {
  const normalized = hex.startsWith("0x") ? hex.slice(2) : hex;
  return Uint8Array.from(Buffer.from(normalized, "hex"));
}

function fieldToSuiBytes(value: bigint): Uint8Array {
  const bytes = Buffer.alloc(32);
  let n = value;
  for (let i = 0; i < 32; i += 1) {
    bytes[i] = Number(n & 0xffn);
    n >>= 8n;
  }
  return bytes;
}

function toHex(bytes: Uint8Array | Buffer): string {
  return `0x${Buffer.from(bytes).toString("hex")}`;
}

function reverseHexToBytes(hex: string): Uint8Array {
  return Uint8Array.from(Buffer.from(hex, "hex").reverse());
}

function findEventField(events: any[] | undefined, typeSuffix: string, field: string): string | undefined {
  const event = events?.find((candidate) => typeof candidate.type === "string" && candidate.type.endsWith(typeSuffix));
  const value = event?.parsedJson?.[field];
  return value === undefined ? undefined : String(value);
}

function btc(cmd: string): string {
  return bitcoinCli(cmd);
}

function assertSuiSuccess(label: string, result: any) {
  const status = result.effects?.status;
  if (status?.status !== "success") {
    throw new Error(`${label} failed: ${JSON.stringify(status)}`);
  }
}

function bytesField(value: unknown): Uint8Array | null {
  if (!Array.isArray(value)) return null;
  const bytes = value.map((entry) => Number(entry));
  if (!bytes.every((entry) => Number.isInteger(entry) && entry >= 0 && entry <= 255)) return null;
  return Uint8Array.from(bytes);
}

function bigintField(value: unknown): bigint | null {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isFinite(value)) return BigInt(Math.trunc(value));
  if (typeof value === "string" && /^\d+$/.test(value)) return BigInt(value);
  return null;
}

function numberField(value: unknown): number | null {
  const valueBigint = bigintField(value);
  if (valueBigint == null || valueBigint > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(valueBigint);
}

interface IkaSuiSigningConfig {
  network: "testnet" | "mainnet";
  dWalletId: string;
  dWalletCapObjectId: string;
  networkEncryptionKeyId: string;
  ikaCoinObjectId: string;
  suiCoinObjectId: string;
  encryptedUserSecretKeyShareId: string;
}

function requireIkaSuiSigningConfig(): IkaSuiSigningConfig {
  const ikaState = state.ikaSui ?? {};
  const config = {
    network: (process.env.UTXOPIA_SUI_IKA_NETWORK || ikaState.network || "testnet") as "testnet" | "mainnet",
    dWalletId: process.env.UTXOPIA_SUI_IKA_DWALLET_ID || ikaState.dWalletId || "",
    dWalletCapObjectId: process.env.UTXOPIA_SUI_IKA_DWALLET_CAP_ID || ikaState.dWalletCapObjectId || "",
    networkEncryptionKeyId:
      process.env.UTXOPIA_SUI_IKA_NETWORK_ENCRYPTION_KEY_ID || ikaState.networkEncryptionKeyId || "",
    ikaCoinObjectId: process.env.UTXOPIA_SUI_IKA_COIN_ID || ikaState.ikaCoinObjectId || "",
    suiCoinObjectId: process.env.UTXOPIA_SUI_IKA_SUI_COIN_ID || ikaState.suiCoinObjectId || "",
    encryptedUserSecretKeyShareId:
      process.env.UTXOPIA_SUI_IKA_ENCRYPTED_USER_SECRET_KEY_SHARE_ID ||
      ikaState.encryptedUserSecretKeyShareId ||
      "",
  };
  const missing = Object.entries(config)
    .filter(([key, value]) => key !== "network" && !value)
    .map(([key]) => key);
  if (missing.length > 0) {
    throw new Error(
      [
        `Sui Ika signing mode is missing: ${missing.join(", ")}`,
        "Fund the relayer with Coin<IKA> and make sure it owns a dWallet cap, then run:",
        "  UTXOPIA_SUI_IKA_AUTO_SELECT=1 bun run sui:ika:discover",
        "You can also provide explicit UTXOPIA_SUI_IKA_* object ID env vars.",
      ].join("\n"),
    );
  }
  if (config.network !== "testnet" && config.network !== "mainnet") {
    throw new Error("UTXOPIA_SUI_IKA_NETWORK must be `testnet` or `mainnet`");
  }
  return config;
}

async function submitNativeIkaSigning(message: Uint8Array, config: IkaSuiSigningConfig) {
  const ikaAdapter = new UTXOpiaSuiIkaAdapter({
    rpcUrl: SUI_RPC_URL,
    network: config.network,
    dWalletId: config.dWalletId,
    dWalletCapObjectId: config.dWalletCapObjectId,
    networkEncryptionKeyId: config.networkEncryptionKeyId,
    ikaCoinObjectId: config.ikaCoinObjectId,
    suiCoinObjectId: config.suiCoinObjectId,
    encryptedUserSecretKeyShareId: config.encryptedUserSecretKeyShareId,
    userShareEncryptionKeys: await loadOrCreateIkaUserShareKeys(),
    suiPaymentReturnAddress: process.env.UTXOPIA_SUI_RELAYER_ADDRESS || state.relayer?.address,
  });
  const ikaClient = ikaAdapter.createClient();
  await ikaClient.initialize();

  console.log("Requesting Sui Ika global Taproot presign...");
  const presignTx = await ikaAdapter.buildRequestGlobalTaprootPresignTransaction();
  const presignRequestResult = await executeTransactionKind(presignTx.bytes);
  assertSuiSuccess("Ika global Taproot presign request", presignRequestResult);
  const presignId = findCreatedObjectId(presignRequestResult, "coordinator_inner::PresignSession");
  if (!presignId) {
    throw new Error(`Ika presign request ${presignRequestResult.digest} did not create a PresignSession`);
  }

  const waitOptions = {
    timeout: Number(process.env.UTXOPIA_SUI_IKA_WAIT_TIMEOUT_MS ?? "120000"),
    interval: Number(process.env.UTXOPIA_SUI_IKA_WAIT_INTERVAL_MS ?? "1000"),
    maxInterval: Number(process.env.UTXOPIA_SUI_IKA_WAIT_MAX_INTERVAL_MS ?? "5000"),
  };
  console.log(`Waiting for Sui Ika presign ${presignId} to complete...`);
  await ikaClient.getPresignInParticularState(presignId, "Completed", waitOptions);

  console.log("Requesting Sui Ika Taproot signature...");
  const signTx = await ikaAdapter.buildTaprootSignWithPublicSharesTransaction({
    presignId,
    message,
  });
  const signRequestResult = await executeTransactionKind(signTx.bytes);
  assertSuiSuccess("Ika Taproot sign request", signRequestResult);
  const signId = findCreatedObjectId(signRequestResult, "coordinator_inner::SignSession");
  if (!signId) {
    throw new Error(`Ika sign request ${signRequestResult.digest} did not create a SignSession`);
  }

  console.log(`Waiting for Sui Ika signature ${signId} to complete...`);
  const sign = await ikaClient.getSignInParticularState(
    signId,
    Curve.SECP256K1,
    SignatureAlgorithm.Taproot,
    "Completed",
    waitOptions,
  );

  return {
    dWalletId: config.dWalletId,
    dWalletCapObjectId: config.dWalletCapObjectId,
    presignRequestTxDigest: presignRequestResult.digest,
    presignId,
    signRequestTxDigest: signRequestResult.digest,
    signId,
    signatureHex: extractCompletedSignatureHex(sign),
  };
}

function findCreatedObjectId(result: any, objectTypeSuffix: string): string | undefined {
  const created = result.objectChanges?.find((change: any) =>
    change.type === "created" &&
    typeof change.objectType === "string" &&
    change.objectType.endsWith(objectTypeSuffix)
  );
  return created?.objectId;
}

function extractCompletedSignatureHex(sign: any): string {
  const signature =
    sign?.state?.Completed?.signature ??
    sign?.state?.completed?.signature ??
    sign?.state?.fields?.Completed?.fields?.signature;
  if (Array.isArray(signature)) {
    return Buffer.from(signature).toString("hex");
  }
  if (signature instanceof Uint8Array) {
    return Buffer.from(signature).toString("hex");
  }
  return typeof signature === "string" ? signature : "";
}

async function refreshObjectRef(objectId: string) {
  const client = new SuiJsonRpcClient({
    url: SUI_RPC_URL,
    network: "testnet",
  });
  const object = await client.getObject({ id: objectId });
  if (!object.data?.version || !object.data.digest) {
    throw new Error(`Could not refresh Sui object ref for ${objectId}`);
  }
  return {
    objectId,
    version: object.data.version,
    digest: object.data.digest,
  };
}

async function assertVerifiedDepositMatches(expected: {
  objectId: string;
  depositTxid: Uint8Array;
  depositVout: number;
  amountSats: bigint;
  opReturnPayload: Uint8Array;
  commitment: Uint8Array;
  verifiedRoot: Uint8Array;
}) {
  const client = new SuiJsonRpcClient({
    url: SUI_RPC_URL,
    network: "testnet",
  });
  const object = await client.getObject({
    id: expected.objectId,
    options: { showContent: true, showType: true },
  });
  const data = object.data;
  if (!data?.type?.endsWith("::btc_light_client::VerifiedBtcDeposit")) {
    throw new Error(`Sui object ${expected.objectId} is not a VerifiedBtcDeposit`);
  }
  const content = data.content as any;
  const fields = content?.fields as Record<string, unknown> | undefined;
  if (!fields) {
    throw new Error(`Sui object ${expected.objectId} has no parsed fields`);
  }

  assertHexField("deposit_txid", bytesField(fields.deposit_txid), expected.depositTxid);
  assertNumberField("deposit_vout", numberField(fields.deposit_vout), expected.depositVout);
  assertBigintField("amount_sats", bigintField(fields.amount_sats), expected.amountSats);
  assertHexField("op_return_payload", bytesField(fields.op_return_payload), expected.opReturnPayload);
  assertHexField("commitment", bytesField(fields.commitment), expected.commitment);
  assertHexField("verified_root", bytesField(fields.verified_root), expected.verifiedRoot);
}

function assertHexField(label: string, actual: Uint8Array | null, expected: Uint8Array) {
  if (!actual || toHex(actual) !== toHex(expected)) {
    throw new Error(`VerifiedBtcDeposit ${label} mismatch`);
  }
}

function assertNumberField(label: string, actual: number | null, expected: number) {
  if (actual !== expected) {
    throw new Error(`VerifiedBtcDeposit ${label} mismatch`);
  }
}

function assertBigintField(label: string, actual: bigint | null, expected: bigint) {
  if (actual !== expected) {
    throw new Error(`VerifiedBtcDeposit ${label} mismatch`);
  }
}
