import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import path from "node:path";
import { Curve, UserShareEncryptionKeys } from "@ika.xyz/sdk";
import { ROOT } from "./shared";

export async function loadOrCreateIkaUserShareKeys(): Promise<UserShareEncryptionKeys> {
  const secretPath = path.join(ROOT, "chains/sui/.secrets/ika-user-share-keys.hex");
  const envSeed = process.env.UTXOPIA_SUI_IKA_USER_SHARE_SEED_HEX;
  const envKeys = process.env.UTXOPIA_SUI_IKA_USER_SHARE_KEYS_HEX;

  if (envKeys) {
    return UserShareEncryptionKeys.fromShareEncryptionKeysBytes(hexToBytes(envKeys));
  }

  if (existsSync(secretPath)) {
    return UserShareEncryptionKeys.fromShareEncryptionKeysBytes(hexToBytes(readFileSync(secretPath, "utf8").trim()));
  }

  const seed = envSeed ? hexToBytes(envSeed) : new Uint8Array(randomBytes(32));
  if (seed.length !== 32) {
    throw new Error("UTXOPIA_SUI_IKA_USER_SHARE_SEED_HEX must be 32 bytes hex");
  }

  const keys = await UserShareEncryptionKeys.fromRootSeedKey(seed, Curve.SECP256K1);
  mkdirSync(path.dirname(secretPath), { recursive: true });
  writeFileSync(secretPath, `${bytesToHex(keys.toShareEncryptionKeysBytes())}\n`, { mode: 0o600 });
  return keys;
}

export function hexToBytes(hex: string): Uint8Array {
  const normalized = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (!/^[0-9a-fA-F]*$/.test(normalized) || normalized.length % 2 !== 0) {
    throw new Error("invalid hex string");
  }
  return Uint8Array.from(Buffer.from(normalized, "hex"));
}

export function bytesToHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}
