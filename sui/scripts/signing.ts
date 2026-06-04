import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { ROOT } from "./shared";

export function activeSuiAddress(): string {
  const result = spawnSync("sui", ["client", "active-address"], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to read active Sui address");
  }
  return result.stdout.trim();
}

export function loadActiveEd25519Keypair(): Ed25519Keypair {
  const activeAddress =
    process.env.UTXOPIA_SUI_SIGNER_ADDRESS ??
    process.env.UTXOPIA_SUI_RELAYER_ADDRESS ??
    activeSuiAddress();
  const keystorePath =
    process.env.UTXOPIA_SUI_KEYPAIR_PATH ??
    process.env.UTXOPIA_SUI_RELAYER_KEYPAIR_PATH ??
    path.join(os.homedir(), ".sui/sui_config/sui.keystore");
  if (!existsSync(keystorePath)) {
    throw new Error(`Sui keystore not found at ${keystorePath}`);
  }

  const keys = JSON.parse(readFileSync(keystorePath, "utf8")) as string[];
  for (const encoded of keys) {
    const decoded = Uint8Array.from(Buffer.from(encoded, "base64"));
    if (decoded[0] !== 0) {
      continue;
    }
    const keypair = Ed25519Keypair.fromSecretKey(decoded.slice(1));
    if (keypair.toSuiAddress() === activeAddress) {
      return keypair;
    }
  }

  throw new Error(`No Ed25519 key for active Sui address ${activeAddress} in ${keystorePath}`);
}

export async function executeTransactionKind(bytes: Uint8Array) {
  const tx = Transaction.fromKind(bytes);
  return executeBuiltTransaction(tx);
}

export async function executeBuiltTransaction(tx: Transaction) {
  const client = new SuiJsonRpcClient({
    url: process.env.UTXOPIA_SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443",
    network: "testnet",
  });
  const signer = loadActiveEd25519Keypair();
  tx.setSender(signer.toSuiAddress());
  tx.setGasBudget(BigInt(process.env.UTXOPIA_SUI_GAS_BUDGET ?? "100000000"));

  const result = await client.signAndExecuteTransaction({
    signer,
    transaction: tx,
    options: {
      showEffects: true,
      showEvents: true,
      showObjectChanges: true,
    },
  });
  await client.waitForTransaction({
    digest: result.digest,
    options: {
      showEffects: true,
    },
  });
  return result;
}
