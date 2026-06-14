#!/usr/bin/env bun
import { Curve, IkaTransaction } from "@ika.xyz/sdk";
import { Transaction } from "@mysten/sui/transactions";
import { readState, writeState } from "./shared";
import { hexToBytes, loadOrCreateIkaUserShareKeys } from "./ika-user-share-keys";
import { assertSuiSuccess } from "./lib/sui-tx";
import { executeBuiltTransaction } from "./signing";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";

const state = readState();
const ikaState = state.ikaSui ?? {};
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const network = (process.env.UTXOPIA_SUI_IKA_NETWORK ?? ikaState.network ?? "testnet") as "testnet" | "mainnet";
const dWalletId = required("UTXOPIA_SUI_IKA_DWALLET_ID", process.env.UTXOPIA_SUI_IKA_DWALLET_ID || ikaState.dWalletId);
const encryptedUserSecretKeyShareId = required(
  "UTXOPIA_SUI_IKA_ENCRYPTED_USER_SECRET_KEY_SHARE_ID",
  process.env.UTXOPIA_SUI_IKA_ENCRYPTED_USER_SECRET_KEY_SHARE_ID || ikaState.encryptedUserSecretKeyShareId,
);

const adapter = new UTXOpiaSuiIkaAdapter({ rpcUrl, network });
const ikaClient = adapter.createClient();
await ikaClient.initialize();
const userShareEncryptionKeys = await loadOrCreateIkaUserShareKeys();
const dWallet = await ikaClient.getDWallet(dWalletId);
const userPublicOutput = ikaState.dWalletUserPublicOutputHex
  ? hexToBytes(ikaState.dWalletUserPublicOutputHex)
  : getAwaitingPublicOutput(dWallet);

const tx = new Transaction();
const ikaTx = new IkaTransaction({
  ikaClient,
  transaction: tx,
  userShareEncryptionKeys,
});
await ikaTx.acceptEncryptedUserShare({
  dWallet,
  userPublicOutput,
  encryptedUserSecretKeyShareId,
});

const result = await executeBuiltTransaction(tx);
assertSuiSuccess("Ika accept encrypted user share", result);

state.ikaSui = {
  ...ikaState,
  network,
  packages: adapter.ikaConfig.packages,
  objects: adapter.ikaConfig.objects,
  dWalletId,
  encryptedUserSecretKeyShareId,
};
writeState(state);

const updated = await ikaClient.getDWallet(dWalletId);
console.log(JSON.stringify({
  txDigest: result.digest,
  status: result.effects?.status,
  dWalletId,
  encryptedUserSecretKeyShareId,
  dWalletKind: updated.kind,
  dWalletState: Object.keys(updated.state ?? {})[0] ?? null,
}, null, 2));

function getAwaitingPublicOutput(dWallet: any): Uint8Array {
  const publicOutput =
    dWallet?.state?.AwaitingKeyHolderSignature?.public_output ??
    dWallet?.state?.awaitingKeyHolderSignature?.public_output ??
    dWallet?.state?.fields?.AwaitingKeyHolderSignature?.fields?.public_output;
  if (Array.isArray(publicOutput)) {
    return Uint8Array.from(publicOutput);
  }
  if (publicOutput instanceof Uint8Array) {
    return publicOutput;
  }
  if (typeof publicOutput === "string") {
    return Uint8Array.from(Buffer.from(publicOutput, "base64"));
  }
  throw new Error(`dWallet ${dWallet?.id ?? ""} is not awaiting key-holder signature`);
}

function required(name: string, value?: string): string {
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}
