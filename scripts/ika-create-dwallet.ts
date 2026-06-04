#!/usr/bin/env bun
import {
  Curve,
  IkaTransaction,
  prepareDKGAsync,
  publicKeyFromCentralizedDKGOutput,
} from "@ika.xyz/sdk";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { readState, writeState } from "./shared";
import { bytesToHex, loadOrCreateIkaUserShareKeys } from "./ika-user-share-keys";
import { activeSuiAddress, executeBuiltTransaction, loadActiveEd25519Keypair } from "./signing";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";

const state = readState();
const ikaState = state.ikaSui ?? {};
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const network = (process.env.UTXOPIA_SUI_IKA_NETWORK ?? ikaState.network ?? "testnet") as "testnet" | "mainnet";
const relayerAddress = process.env.UTXOPIA_SUI_RELAYER_ADDRESS ?? state.relayer?.address ?? activeSuiAddress();
const force = process.argv.includes("--force") || process.env.UTXOPIA_SUI_IKA_FORCE_CREATE === "1";

const adapter = new UTXOpiaSuiIkaAdapter({ rpcUrl, network });
const ikaClient = adapter.createClient();
await ikaClient.initialize();

if (!force) {
  const existingCaps = await ikaClient.getOwnedDWalletCaps(relayerAddress, undefined, 20);
  const existingCap = (existingCaps.dWalletCaps?.[0] ?? null) as any;
  if (existingCap) {
    await writeKnownState({
      dWalletId: extractDWalletIdFromCap(existingCap) || ikaState.dWalletId || "",
      dWalletCapObjectId: extractCapObjectId(existingCap) || ikaState.dWalletCapObjectId || "",
    });
    console.log(JSON.stringify({
      skipped: true,
      reason: "relayer already owns a dWallet cap; pass --force to create another",
      dWalletCap: existingCap,
    }, null, 2));
    process.exit(0);
  }
}

const sui = new SuiJsonRpcClient({ url: rpcUrl, network: "testnet" });
const signer = loadActiveEd25519Keypair();
const sender = signer.toSuiAddress();
const latestEncryptionKey = await ikaClient.getLatestNetworkEncryptionKey();
const ikaCoinObjectId = process.env.UTXOPIA_SUI_IKA_COIN_ID || ikaState.ikaCoinObjectId;
const suiCoinObjectId = process.env.UTXOPIA_SUI_IKA_SUI_COIN_ID || ikaState.suiCoinObjectId || "__gas__";

if (!ikaCoinObjectId) {
  throw new Error("UTXOPIA_SUI_IKA_COIN_ID missing. Fund relayer with Coin<IKA>, then run UTXOPIA_SUI_IKA_AUTO_SELECT=1 bun run sui:ika:discover.");
}
if (!suiCoinObjectId) {
  throw new Error("UTXOPIA_SUI_IKA_SUI_COIN_ID missing. Run UTXOPIA_SUI_IKA_AUTO_SELECT=1 bun run sui:ika:discover.");
}

const userShareEncryptionKeys = await loadOrCreateIkaUserShareKeys();
const sessionIdentifier = crypto.getRandomValues(new Uint8Array(32));
const dkgInput = await prepareDKGAsync(
  ikaClient,
  Curve.SECP256K1,
  userShareEncryptionKeys,
  sessionIdentifier,
  sender,
);
const dWalletPublicKey = await publicKeyFromCentralizedDKGOutput(Curve.SECP256K1, dkgInput.userPublicOutput);
const dWalletPublicKeyHex = bytesToHex(dWalletPublicKey);
const dWalletXOnlyPubkey = xOnlyFromSecpPublicKey(dWalletPublicKey);
const dWalletUserPublicOutputHex = bytesToHex(dkgInput.userPublicOutput);

const tx = new Transaction();
tx.setSender(sender);
tx.setGasBudget(BigInt(process.env.UTXOPIA_SUI_GAS_BUDGET ?? state.gasBudget ?? "100000000"));
const ikaTx = new IkaTransaction({
  ikaClient,
  transaction: tx,
  userShareEncryptionKeys,
});
if (!(await hasActiveUserEncryptionKey(userShareEncryptionKeys.getSuiAddress()))) {
  await ikaTx.registerEncryptionKey({ curve: Curve.SECP256K1 });
}
const session = ikaTx.registerSessionIdentifier(sessionIdentifier);
const suiPaymentCoin = suiCoinObjectId === "__gas__"
  ? tx.splitCoins(tx.gas, [tx.pure.u64(BigInt(process.env.UTXOPIA_SUI_IKA_SUI_PAYMENT_NANOS ?? "10000000"))])[0]
  : tx.object(suiCoinObjectId);
const dWalletDkgResult = await ikaTx.requestDWalletDKG({
  dkgRequestInput: dkgInput,
  sessionIdentifier: session,
  dwalletNetworkEncryptionKeyId: latestEncryptionKey.id,
  curve: Curve.SECP256K1,
  ikaCoin: tx.object(ikaCoinObjectId),
  suiCoin: suiPaymentCoin,
});
const objectsToTransfer = suiCoinObjectId === "__gas__" ? [dWalletDkgResult[0], suiPaymentCoin] : [dWalletDkgResult[0]];
tx.transferObjects(objectsToTransfer, tx.pure.address(sender));

const result = await executeBuiltTransaction(tx);
assertSuiSuccess("Ika dWallet DKG request", result);

const createdCapObjectId = findCreatedObjectId(result, "coordinator_inner::DWalletCap");
const createdEncryptedShareId = findCreatedObjectId(result, "coordinator_inner::EncryptedUserSecretKeyShare");
const createdDWalletId =
  await findDWalletIdFromCapObject(sui, createdCapObjectId) ||
  findCreatedObjectId(result, "coordinator_inner::DWallet") ||
  "";

await writeKnownState({
  dWalletId: createdDWalletId,
  dWalletCapObjectId: createdCapObjectId ?? "",
  networkEncryptionKeyId: latestEncryptionKey.id,
  ikaCoinObjectId,
  suiCoinObjectId,
  dWalletPublicKeyHex,
  dWalletXOnlyPubkey,
  encryptedUserSecretKeyShareId: createdEncryptedShareId,
  dWalletUserPublicOutputHex,
});

console.log(JSON.stringify({
  txDigest: result.digest,
  status: result.effects?.status,
  dWalletId: createdDWalletId,
  dWalletCapObjectId: createdCapObjectId,
  encryptedUserSecretKeyShareId: createdEncryptedShareId,
  dWalletPublicKeyHex,
  dWalletXOnlyPubkey,
  dWalletUserPublicOutputHex,
  note: "Run `UTXOPIA_NETWORK=sui-regtest ./scripts/sync-env.sh` to refresh backend/web env.",
}, null, 2));

async function writeKnownState(input: {
  dWalletId?: string;
  dWalletCapObjectId?: string;
  networkEncryptionKeyId?: string;
  ikaCoinObjectId?: string;
  suiCoinObjectId?: string;
  dWalletPublicKeyHex?: string;
  dWalletXOnlyPubkey?: string;
  encryptedUserSecretKeyShareId?: string;
  dWalletUserPublicOutputHex?: string;
}) {
  const nextIkaState = state.ikaSui ?? {};
  state.ikaSui = {
    ...nextIkaState,
    network,
    packages: adapter.ikaConfig.packages,
    objects: adapter.ikaConfig.objects,
    networkEncryptionKeyId: input.networkEncryptionKeyId ?? nextIkaState.networkEncryptionKeyId ?? "",
    dWalletId: input.dWalletId || nextIkaState.dWalletId || "",
    dWalletCapObjectId: input.dWalletCapObjectId || nextIkaState.dWalletCapObjectId || "",
    ikaCoinObjectId: input.ikaCoinObjectId ?? nextIkaState.ikaCoinObjectId ?? "",
    suiCoinObjectId: input.suiCoinObjectId ?? nextIkaState.suiCoinObjectId ?? "",
    dWalletPublicKeyHex: input.dWalletPublicKeyHex ?? nextIkaState.dWalletPublicKeyHex ?? "",
    dWalletXOnlyPubkey: input.dWalletXOnlyPubkey ?? nextIkaState.dWalletXOnlyPubkey ?? "",
    encryptedUserSecretKeyShareId:
      input.encryptedUserSecretKeyShareId ?? nextIkaState.encryptedUserSecretKeyShareId ?? "",
    dWalletUserPublicOutputHex:
      input.dWalletUserPublicOutputHex ?? nextIkaState.dWalletUserPublicOutputHex ?? "",
  };

  if (input.dWalletXOnlyPubkey) {
    state.ika = {
      ...(state.ika ?? {}),
      dwalletXOnlyPubkey: input.dWalletXOnlyPubkey,
    };
    state.signingMode = "ika" as any;
    state.depositMode = "direct" as any;
  }

  writeState(state);
}

function assertSuiSuccess(label: string, result: any) {
  const status = result.effects?.status;
  if (status?.status !== "success") {
    throw new Error(`${label} failed: ${JSON.stringify(status)}`);
  }
}

function findCreatedObjectId(result: any, objectTypeSuffix: string): string | undefined {
  const created = result.objectChanges?.find((change: any) =>
    change.type === "created" &&
    typeof change.objectType === "string" &&
    change.objectType.endsWith(objectTypeSuffix)
  );
  return created?.objectId;
}

async function findDWalletIdFromCapObject(client: SuiJsonRpcClient, objectId?: string): Promise<string | undefined> {
  if (!objectId) {
    return undefined;
  }
  const object = await client.getObject({
    id: objectId,
    options: { showContent: true, showType: true },
  });
  const fields = (object.data?.content as any)?.fields;
  return fields?.dwallet_id ?? fields?.dwallet?.fields?.id?.id ?? fields?.dwallet?.id;
}

function extractCapObjectId(cap: any): string {
  return cap?.id?.id ?? cap?.id ?? cap?.objectId ?? "";
}

function extractDWalletIdFromCap(cap: any): string {
  return cap?.dwallet_id ?? cap?.dwalletId ?? cap?.dwallet?.id?.id ?? "";
}

async function hasActiveUserEncryptionKey(address: string): Promise<boolean> {
  try {
    await ikaClient.getActiveEncryptionKey(address);
    return true;
  } catch {
    return false;
  }
}

function xOnlyFromSecpPublicKey(publicKey: Uint8Array): string {
  if (publicKey.length === 33 && (publicKey[0] === 2 || publicKey[0] === 3)) {
    return bytesToHex(publicKey.slice(1));
  }
  if (publicKey.length === 32) {
    return bytesToHex(publicKey);
  }
  if (publicKey.length > 33 && (publicKey.at(-33) === 2 || publicKey.at(-33) === 3)) {
    return bytesToHex(publicKey.slice(-32));
  }
  throw new Error(`Unsupported secp256k1 public key length ${publicKey.length}`);
}
