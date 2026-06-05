#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { extractUtxopiaDepositOpReturn, type BitcoinTransaction } from "@utxopia/sdk/btc-client";
import { UTXOpiaSuiAdapter } from "@utxopia/sdk/sui";

const ROOT = path.resolve(import.meta.dir, "../../..");
const CIRCUITS_DIR = process.env.UTXOPIA_CIRCUITS_DIR
  ? path.resolve(process.env.UTXOPIA_CIRCUITS_DIR)
  : path.resolve(ROOT, "../utxopia-circuits");
const objectId = `0x${"1".padStart(64, "0")}`;

async function main() {
  const adapter = new UTXOpiaSuiAdapter({
    rpcUrl: "http://127.0.0.1:9000",
    packageId: objectId,
    poolObjectId: objectId,
    poolInitialSharedVersion: 1,
    commitmentTreeObjectId: objectId,
    commitmentTreeInitialSharedVersion: 1,
    utxoSetObjectId: objectId,
    utxoSetInitialSharedVersion: 1,
    lightClientObjectId: objectId,
    lightClientInitialSharedVersion: 1,
    adminCapObjectId: objectId,
    adminCapVersion: "1",
    adminCapDigest: "11111111111111111111111111111111",
    verifyingKeyRegistryObjectId: objectId,
    verifyingKeyRegistryInitialSharedVersion: 1,
    nullifierRegistryObjectId: objectId,
    nullifierRegistryInitialSharedVersion: 1,
    redemptionQueueObjectId: objectId,
    redemptionQueueInitialSharedVersion: 1,
    redemptionCapObjectId: objectId,
    redemptionCapVersion: "1",
    redemptionCapDigest: "11111111111111111111111111111111",
  });

  const checks: Array<[string, () => Promise<string>]> = [
    ["bitcoin deposit OP_RETURN parser", verifyBitcoinDepositEvidence],
    ["Sui Groth16 VK export", verifySuiVkeyExport],
    ["JoinSplit transfer PTB", () => verifyJoinSplitPtb(adapter)],
    ["proof-checked BTC redemption PTB", () => verifyRedemptionPtb(adapter)],
    ["Ika signing approval PTB", () => verifyIkaApprovalPtb(adapter)],
    ["BTC redemption completion PTB", () => verifyRedemptionCompletionPtb(adapter)],
  ];

  for (const [name, check] of checks) {
    const detail = await check();
    console.log(`PASS ${name}: ${detail}`);
  }
}

async function verifyBitcoinDepositEvidence(): Promise<string> {
  const tx: BitcoinTransaction = {
    txid: "demo",
    version: 2,
    locktime: 0,
    vin: [],
    vout: [
      {
        scriptpubkey: `6a49${"63"}${"aa".repeat(8)}${"11".repeat(32)}${"22".repeat(32)}`,
        scriptpubkey_asm: "OP_RETURN",
        scriptpubkey_type: "op_return",
        value: 0,
      },
    ],
    size: 0,
    weight: 0,
    fee: 0,
    status: { confirmed: true, block_height: 1 },
  };

  const opReturn = extractUtxopiaDepositOpReturn(tx);
  if (!opReturn) {
    throw new Error("missing UTXOpia deposit OP_RETURN");
  }
  return `poolTag=${opReturn.poolTag.length} ephemeral=${opReturn.ephemeralPubkey.length} npk=${opReturn.npk.length}`;
}

async function verifySuiVkeyExport(): Promise<string> {
  const vkeyPath = path.join(CIRCUITS_DIR, "build/joinsplit_1x1/joinsplit_1x1.vkey.json");
  if (!existsSync(vkeyPath)) {
    throw new Error(`missing ${vkeyPath}`);
  }

  const result = spawnSync("cargo", [
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

  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout);
  }

  const exported = JSON.parse(result.stdout) as {
    nPublic: number;
    rawVerifyingKey: string;
    vkHash: string;
  };
  if (!exported.rawVerifyingKey || exported.vkHash.length !== 64) {
    throw new Error("invalid Sui VK export");
  }

  return `nPublic=${exported.nPublic} vkHash=${exported.vkHash.slice(0, 12)}...`;
}

async function verifyJoinSplitPtb(adapter: UTXOpiaSuiAdapter): Promise<string> {
  const tx = await adapter.buildTransactTransaction({
    inputNotes: [{
      commitment: "11".repeat(32),
      nullifier: "22".repeat(32),
      tokenId: "zkbtc",
      leafIndex: 0,
    }],
    outputs: [{
      recipient: "recipient",
      tokenId: "zkbtc",
      amount: 1n,
    }],
    proof: new Uint8Array(),
    boundParamsHash: "33".repeat(32),
    vkHash: new Uint8Array(32).fill(4),
    publicInputs: new Uint8Array(32 * 4).fill(5),
    proofPoints: new Uint8Array(128).fill(6),
    commitmentsOut: [new Uint8Array(32).fill(7)],
  });

  return `bytes=${tx.bytes.length}`;
}

async function verifyRedemptionPtb(adapter: UTXOpiaSuiAdapter): Promise<string> {
  const tx = await adapter.buildRedemptionTransaction({
    inputNotes: [],
    btcAddress: `0014${"22".repeat(20)}`,
    amountSats: 1n,
    maxFeeSats: 1n,
    proof: new Uint8Array(),
    vkHash: new Uint8Array(32).fill(4),
    publicInputs: new Uint8Array(32 * 3).fill(5),
    proofPoints: new Uint8Array(128).fill(6),
    commitmentsOut: [new Uint8Array(32).fill(7)],
  });

  return `bytes=${tx.bytes.length}`;
}

async function verifyIkaApprovalPtb(adapter: UTXOpiaSuiAdapter): Promise<string> {
  const tx = await adapter.buildIkaApprovalTransaction({
    redemptionId: 0,
    sighash: new Uint8Array(32).fill(9),
  });

  return `bytes=${tx.bytes.length}`;
}

async function verifyRedemptionCompletionPtb(adapter: UTXOpiaSuiAdapter): Promise<string> {
  const tx = await adapter.buildCompleteRedemptionTransaction({
    redemptionId: 0,
    btcTxid: new Uint8Array(32).fill(10),
    blockHash: new Uint8Array(32).fill(11),
    txIndex: 0,
    merkleSiblings: [],
    pathBits: 0,
    rawTx: new Uint8Array([1, 2, 3]),
  });

  return `bytes=${tx.bytes.length}`;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
