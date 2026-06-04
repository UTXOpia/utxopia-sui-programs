#!/usr/bin/env bun
import {
  Curve,
  IkaTransaction,
  prepareImportedKeyDWalletVerification,
} from "@ika.xyz/sdk";
import { Transaction } from "@mysten/sui/transactions";
import { readState, writeState } from "./shared";
import { hexToBytes, loadOrCreateIkaUserShareKeys } from "./ika-user-share-keys";
import { executeBuiltTransaction, loadActiveEd25519Keypair } from "./signing";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";

const state = readState();
const ikaState = state.ikaSui ?? {};
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const privateKey = hexToBytes(requiredEnv("UTXOPIA_SUI_IKA_IMPORT_PRIVATE_KEY_HEX"));
if (privateKey.length !== 32) {
  throw new Error("UTXOPIA_SUI_IKA_IMPORT_PRIVATE_KEY_HEX must be 32 bytes hex");
}

const ikaCoinObjectId = process.env.UTXOPIA_SUI_IKA_COIN_ID || ikaState.ikaCoinObjectId;
const suiCoinObjectId = process.env.UTXOPIA_SUI_IKA_SUI_COIN_ID || ikaState.suiCoinObjectId;
const networkEncryptionKeyId =
  process.env.UTXOPIA_SUI_IKA_NETWORK_ENCRYPTION_KEY_ID || ikaState.networkEncryptionKeyId;
if (!ikaCoinObjectId) {
  throw new Error("UTXOPIA_SUI_IKA_COIN_ID missing. Fund the relayer with Coin<IKA>, then run bun run sui:ika:discover.");
}
if (!suiCoinObjectId) {
  throw new Error("UTXOPIA_SUI_IKA_SUI_COIN_ID missing. Run UTXOPIA_SUI_IKA_AUTO_SELECT=1 bun run sui:ika:discover.");
}
if (!networkEncryptionKeyId) {
  throw new Error("UTXOPIA_SUI_IKA_NETWORK_ENCRYPTION_KEY_ID missing. Run bun run sui:ika:status.");
}

const signer = loadActiveEd25519Keypair();
const sender = signer.toSuiAddress();
const adapter = new UTXOpiaSuiIkaAdapter({
  rpcUrl,
  network: (ikaState.network ?? "testnet") as "testnet" | "mainnet",
});
const ikaClient = adapter.createClient();
await ikaClient.initialize();

const userShareEncryptionKeys = await loadOrCreateIkaUserShareKeys();
const sessionIdentifier = crypto.getRandomValues(new Uint8Array(32));
const importInput = await prepareImportedKeyDWalletVerification(
  ikaClient,
  Curve.SECP256K1,
  sessionIdentifier,
  sender,
  userShareEncryptionKeys,
  privateKey,
);

const tx = new Transaction();
tx.setSender(sender);
tx.setGasBudget(BigInt(process.env.UTXOPIA_SUI_GAS_BUDGET ?? "100000000"));
const ikaTx = new IkaTransaction({
  ikaClient,
  transaction: tx,
  userShareEncryptionKeys,
});
const session = ikaTx.registerSessionIdentifier(sessionIdentifier);
await ikaTx.requestImportedKeyDWalletVerification({
  importDWalletVerificationRequestInput: importInput,
  curve: Curve.SECP256K1,
  signerPublicKey: signer.getPublicKey().toRawBytes(),
  sessionIdentifier: session,
  ikaCoin: tx.object(ikaCoinObjectId),
  suiCoin: tx.object(suiCoinObjectId),
});

const result = await executeBuiltTransaction(tx);
const created = result.objectChanges?.filter((change: any) => change.type === "created") ?? [];
const importedCap = created.find((change: any) =>
  typeof change.objectType === "string" && change.objectType.endsWith("::coordinator_inner::ImportedKeyDWalletCap")
);

state.ikaSui = {
  ...ikaState,
  network: ikaState.network ?? "testnet",
  packages: adapter.ikaConfig.packages,
  objects: adapter.ikaConfig.objects,
  networkEncryptionKeyId,
  ikaCoinObjectId,
  suiCoinObjectId,
  dWalletCapObjectId: importedCap?.objectId ?? ikaState.dWalletCapObjectId ?? "",
};
writeState(state);

console.log(JSON.stringify({
  txDigest: result.digest,
  status: result.effects?.status,
  importedKeyDWalletCap: importedCap ?? null,
  note: "Run `UTXOPIA_SUI_IKA_AUTO_SELECT=1 bun run sui:ika:discover && UTXOPIA_NETWORK=sui-testnet ./scripts/sync-env.sh` to resolve dWalletId and refresh env.",
}, null, 2));

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}
