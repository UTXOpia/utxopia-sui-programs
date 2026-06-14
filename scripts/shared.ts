import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";

export interface SuiObjectRef {
  objectId: string;
  version: string;
  digest: string;
}

export interface SuiSharedObjectRef {
  objectId: string;
  initialSharedVersion: string;
}

export interface UtxopiaSuiState {
  network: string;
  rpcUrl?: string;
  gasBudget?: string;
  signingMode?: string;
  depositMode?: string;
  relayer?: {
    address?: string;
    keypairPath?: string;
    keyScheme?: string;
  };
  suins?: {
    parentName?: string;
    parentNftId?: string;
    targetAddress?: string;
  };
  ikaSui?: {
    network?: string;
    packages?: Record<string, string>;
    objects?: Record<string, {
      objectID: string;
      initialSharedVersion: number;
    }>;
    dWalletId?: string;
    dWalletCapObjectId?: string;
    networkEncryptionKeyId?: string;
    ikaCoinObjectId?: string;
    suiCoinObjectId?: string;
    dWalletPublicKeyHex?: string;
    dWalletXOnlyPubkey?: string;
    encryptedUserSecretKeyShareId?: string;
    dWalletUserPublicOutputHex?: string;
  };
  ika?: {
    programId?: string;
    grpcEndpoint?: string;
    dwallet?: string;
    dwalletXOnlyPubkey?: string;
    cpiAuthorityBump?: number;
  };
  packageId?: string;
  adminCap?: SuiObjectRef;
  upgradeCap?: SuiObjectRef;
  pool?: SuiSharedObjectRef;
  commitmentTree?: SuiSharedObjectRef;
  btcDepositRegistry?: SuiSharedObjectRef;
  utxoSet?: SuiSharedObjectRef;
  lightClient?: SuiSharedObjectRef;
  lightClientAdminCap?: SuiObjectRef;
  nullifierRegistry?: SuiSharedObjectRef;
  redemptionQueue?: SuiSharedObjectRef;
  redemptionCap?: SuiObjectRef;
  verifyingKeyRegistry?: SuiSharedObjectRef;
  tokenRegistry?: SuiSharedObjectRef;
  registeredTokens?: Record<string, {
    coinType: string;
    metadataId: string;
    minDeposit: string;
    maxDeposit: string;
    depositCap: string;
    feeBps: number;
    registerTxDigest?: string;
  }>;
  lastRedemption?: {
    redemptionId: string;
    requestTxDigest: string;
    ikaApprovalTxDigest?: string;
    completeTxDigest?: string;
  };
  lastTransact?: {
    circuit: string;
    shieldTxDigest?: string;
    txDigest: string;
    nullifier: string;
    commitmentOut: string;
    proofPublicInputs: string;
  };
  vk?: Record<string, {
    nInputs: number;
    nOutputs: number;
    nPublic: number;
    vkHash: string;
    rawVerifyingKey: string;
    registerTxDigest?: string;
  }>;
}

// Repo root (post-flatten: scripts/ sits directly under the repo root).
export const ROOT = path.resolve(import.meta.dir, "..");
export const DEFAULT_STATE_FILE = path.join(ROOT, "utxopia-sui-state.json");
export const LEGACY_STATE_FILE = path.join(ROOT, "sui-poc-state.json");

export function stateFile(): string {
  if (process.env.UTXOPIA_SUI_STATE_FILE) {
    return process.env.UTXOPIA_SUI_STATE_FILE;
  }
  return existsSync(DEFAULT_STATE_FILE) ? DEFAULT_STATE_FILE : LEGACY_STATE_FILE;
}

export function readState(): UtxopiaSuiState {
  const file = stateFile();
  if (!existsSync(file)) {
    return { network: process.env.UTXOPIA_SUI_NETWORK ?? "testnet" };
  }

  return JSON.parse(readFileSync(file, "utf8")) as UtxopiaSuiState;
}

export function writeState(state: UtxopiaSuiState) {
  writeFileSync(stateFile(), `${JSON.stringify(state, null, 2)}\n`);
}

export function requireState<T>(value: T | undefined, label: string): T {
  if (!value) {
    throw new Error(`${label} missing from ${stateFile()}`);
  }
  return value;
}

export function parseJsonFromStdout(stdout: string): unknown {
  const start = stdout.indexOf("{");
  const end = stdout.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error(`No JSON object in command output:\n${stdout}`);
  }
  return JSON.parse(stdout.slice(start, end + 1));
}

export function objectRefFromChange(change: any): SuiObjectRef | undefined {
  if (!change) {
    return undefined;
  }
  const objectId = change.objectId;
  const version = change.version;
  const digest = change.digest;
  if (!objectId || !version || !digest) {
    return undefined;
  }
  return { objectId, version: String(version), digest };
}

export function sharedRefFromChange(change: any): SuiSharedObjectRef | undefined {
  if (!change) {
    return undefined;
  }
  const initialSharedVersion =
    change.initialSharedVersion ??
    change.owner?.Shared?.initial_shared_version ??
    change.owner?.Shared?.initialSharedVersion;
  if (!change.objectId || initialSharedVersion === undefined) {
    return undefined;
  }
  return {
    objectId: change.objectId,
    initialSharedVersion: String(initialSharedVersion),
  };
}

export function findCreatedObject(changes: any[], typeSuffix: string) {
  return changes.find((change) => change.type === "created" && typeof change.objectType === "string" && change.objectType.endsWith(typeSuffix));
}
