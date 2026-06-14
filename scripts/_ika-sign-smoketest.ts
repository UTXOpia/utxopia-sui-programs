#!/usr/bin/env bun
// Focused proof that the provisioned Sui Ika dWallet can produce a valid Taproot
// (BIP340 Schnorr) signature for its advertised x-only pubkey. Mirrors
// regtest-flow.ts::submitNativeIkaSigning but signs a throwaway 32-byte digest
// and verifies the result locally — no BTC/light-client dependency.
import { Curve, SignatureAlgorithm } from "@ika.xyz/sdk";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";
import { schnorr } from "@noble/curves/secp256k1.js";
import { createHash } from "node:crypto";
import { readState } from "./shared";
const sha256 = (b: Uint8Array) => new Uint8Array(createHash("sha256").update(b).digest());
import { executeTransactionKind } from "./signing";
import { loadOrCreateIkaUserShareKeys } from "./ika-user-share-keys";

const state = readState();
const k = state.ikaSui!;
const SUI_RPC_URL = state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";

const message = sha256(new TextEncoder().encode("utxopia-ika-smoketest-2026-06-10"));
console.log("test message (32B):", Buffer.from(message).toString("hex"));

const ikaAdapter = new UTXOpiaSuiIkaAdapter({
  rpcUrl: SUI_RPC_URL,
  network: "testnet",
  dWalletId: k.dWalletId,
  dWalletCapObjectId: k.dWalletCapObjectId,
  networkEncryptionKeyId: k.networkEncryptionKeyId,
  ikaCoinObjectId: k.ikaCoinObjectId,
  suiCoinObjectId: k.suiCoinObjectId,
  encryptedUserSecretKeyShareId: k.encryptedUserSecretKeyShareId,
  userShareEncryptionKeys: await loadOrCreateIkaUserShareKeys(),
  suiPaymentReturnAddress: state.relayer?.address,
});
const ikaClient = ikaAdapter.createClient();
await ikaClient.initialize();

const waitOptions = { timeout: 180000, interval: 1500, maxInterval: 6000 };

console.log("Requesting global Taproot presign...");
const presignTx = await ikaAdapter.buildRequestGlobalTaprootPresignTransaction();
const presignRes = await executeTransactionKind(presignTx.bytes);
if (presignRes.effects?.status?.status !== "success") throw new Error("presign request failed: " + JSON.stringify(presignRes.effects?.status));
const presignId = findCreated(presignRes, "coordinator_inner::PresignSession");
if (!presignId) throw new Error("no PresignSession created");
console.log("presignId:", presignId, "— waiting for Completed...");
await ikaClient.getPresignInParticularState(presignId, "Completed", waitOptions);

console.log("Requesting Taproot signature...");
const signTx = await ikaAdapter.buildTaprootSignWithPublicSharesTransaction({ presignId, message });
const signRes = await executeTransactionKind(signTx.bytes);
if (signRes.effects?.status?.status !== "success") throw new Error("sign request failed: " + JSON.stringify(signRes.effects?.status));
const signId = findCreated(signRes, "coordinator_inner::SignSession");
if (!signId) throw new Error("no SignSession created");
console.log("signId:", signId, "— waiting for Completed...");
const sign = await ikaClient.getSignInParticularState(signId, Curve.SECP256K1, SignatureAlgorithm.Taproot, "Completed", waitOptions);

const sigHex = extractSig(sign);
console.log("signatureHex:", sigHex, "(", sigHex.length / 2, "bytes )");

const xOnly = k.dWalletXOnlyPubkey!;
console.log("dWallet x-only pubkey:", xOnly);
const sigBytes = Buffer.from(sigHex, "hex");
// BIP340 Schnorr signature is 64 bytes; some encodings prefix a recovery/flag byte.
const sig64 = sigBytes.length === 64 ? sigBytes : sigBytes.subarray(sigBytes.length - 64);
const ok = schnorr.verify(sig64, message, Buffer.from(xOnly, "hex"));
console.log(ok ? "✅ SIGNATURE VERIFIES against dWallet x-only pubkey (BIP340 Schnorr)" : "❌ signature did NOT verify");
if (!ok) process.exit(1);

function findCreated(res: any, suffix: string): string | undefined {
  return res.objectChanges?.find((c: any) => c.type === "created" && typeof c.objectType === "string" && c.objectType.endsWith(suffix))?.objectId;
}
function extractSig(sign: any): string {
  const s = sign?.state?.Completed?.signature ?? sign?.state?.completed?.signature ?? sign?.state?.fields?.Completed?.fields?.signature;
  if (Array.isArray(s)) return Buffer.from(s).toString("hex");
  if (s instanceof Uint8Array) return Buffer.from(s).toString("hex");
  return typeof s === "string" ? s.replace(/^0x/, "") : "";
}
