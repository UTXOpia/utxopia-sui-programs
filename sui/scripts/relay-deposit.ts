#!/usr/bin/env bun
import { UTXOpiaSuiAdapter } from "@utxopia/sdk/sui";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import {
  CommitmentTreeIndex,
  computeJoinSplitCommitmentSync,
  initPoseidon,
} from "@utxopia/sdk";
import { bitcoinCli, waitForEsplora, waitForTxIndexed } from "./lib/regtest-helpers";
import { readState, requireState, writeState } from "./shared";
import { executeTransactionKind } from "./signing";

const ESPLORA_URL = process.env.ESPLORA_URL ?? "http://localhost:3002/regtest/api";
const ZKBTC_TOKEN_ID = 0x7a627463n;

interface RelayArgs {
  txid: string;
  amountSats: bigint;
  opReturn: Uint8Array;
  depositAddress?: string;
  depositVout?: number;
}

const args = parseArgs(process.argv.slice(2));
await initPoseidon();
await waitForEsplora(ESPLORA_URL, 30_000);
await waitForTxIndexed(args.txid, ESPLORA_URL, 60_000);

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const verifiedDeposit = requireState(state.lastVerifiedBtcDeposit, "lastVerifiedBtcDeposit");
const btcDepositRegistry = requireState(state.btcDepositRegistry, "btcDepositRegistry");
const redemptionQueue = requireState(state.redemptionQueue, "redemptionQueue");
const redemptionCap = requireState(state.redemptionCap, "redemptionCap");
const verifyingKeyRegistry = requireState(state.verifyingKeyRegistry, "verifyingKeyRegistry");
const nullifierRegistry = requireState(state.nullifierRegistry, "nullifierRegistry");
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";

const depositVout = args.depositVout ?? findDepositVout(args);
const npk = bytesToBigintBE(args.opReturn.slice(32, 64));
const commitment = computeJoinSplitCommitmentSync(npk, ZKBTC_TOKEN_ID, args.amountSats);
const tree = await rebuildTree();
tree.addCommitment(commitment, args.amountSats);
const offchainPoseidonRoot = tree.getRoot();
await assertVerifiedDepositMatches({
  objectId: verifiedDeposit.objectId,
  depositTxid: reverseHexToBytes(args.txid),
  depositVout,
  amountSats: args.amountSats,
  opReturnPayload: args.opReturn,
  commitment: fieldToSuiBytes(commitment),
  verifiedRoot: fieldToSuiBytes(offchainPoseidonRoot),
});

const adapter = new UTXOpiaSuiAdapter({
  rpcUrl,
  packageId,
  poolObjectId: pool.objectId,
  poolInitialSharedVersion: pool.initialSharedVersion,
  btcDepositRegistryObjectId: btcDepositRegistry.objectId,
  btcDepositRegistryInitialSharedVersion: btcDepositRegistry.initialSharedVersion,
  verifyingKeyRegistryObjectId: verifyingKeyRegistry.objectId,
  verifyingKeyRegistryInitialSharedVersion: verifyingKeyRegistry.initialSharedVersion,
  nullifierRegistryObjectId: nullifierRegistry.objectId,
  nullifierRegistryInitialSharedVersion: nullifierRegistry.initialSharedVersion,
  redemptionQueueObjectId: redemptionQueue.objectId,
  redemptionQueueInitialSharedVersion: redemptionQueue.initialSharedVersion,
  redemptionCapObjectId: redemptionCap.objectId,
  redemptionCapVersion: redemptionCap.version,
  redemptionCapDigest: redemptionCap.digest,
});

const tx = await adapter.buildBtcDepositTransaction({
  verifiedDepositObjectId: verifiedDeposit.objectId,
  verifiedDepositVersion: verifiedDeposit.version,
  verifiedDepositDigest: verifiedDeposit.digest,
});
const result = await executeTransactionKind(tx.bytes);
assertSuiSuccess("Sui BTC deposit relay", result);

const relayCommitments = ((state as any).suiDepositRelayCommitments ?? []) as Array<{
  commitment: string;
  amountSats: string;
}>;
relayCommitments.push({
  commitment: toHex(fieldToSuiBytes(commitment)),
  amountSats: args.amountSats.toString(),
});
(state as any).suiDepositRelayCommitments = relayCommitments;
(state as any).lastSuiDepositRelay = {
  amountSats: args.amountSats.toString(),
  depositTxid: args.txid,
  depositVout,
  opReturn: toHex(args.opReturn),
  commitment: toHex(fieldToSuiBytes(commitment)),
  offchainPoseidonRoot: toHex(fieldToSuiBytes(offchainPoseidonRoot)),
  txDigest: result.digest,
};
writeState(state);

console.log(JSON.stringify({
  ok: true,
  txDigest: result.digest,
  depositTxid: args.txid,
  depositVout,
  amountSats: args.amountSats.toString(),
  commitment: toHex(fieldToSuiBytes(commitment)),
  offchainPoseidonRoot: toHex(fieldToSuiBytes(offchainPoseidonRoot)),
}, null, 2));

function parseArgs(argv: string[]): RelayArgs {
  const map = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) continue;
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${key}`);
    }
    map.set(key.slice(2), value);
    i += 1;
  }

  const txid = map.get("txid") ?? "";
  if (!/^[0-9a-fA-F]{64}$/.test(txid)) {
    throw new Error("--txid must be a 32-byte hex Bitcoin txid");
  }
  const amountText = map.get("amount-sats") ?? "";
  if (!/^[1-9]\d*$/.test(amountText)) {
    throw new Error("--amount-sats must be a positive integer");
  }
  const opReturnHex = map.get("op-return") ?? "";
  if (!/^[0-9a-fA-F]{128}$/.test(opReturnHex)) {
    throw new Error("--op-return must be exactly 64 bytes of hex");
  }
  const depositVoutText = map.get("deposit-vout");
  const depositVout = depositVoutText == null ? undefined : Number(depositVoutText);
  if (depositVout != null && (!Number.isInteger(depositVout) || depositVout < 0)) {
    throw new Error("--deposit-vout must be a non-negative integer");
  }
  const depositAddress = map.get("deposit-address");
  if (depositAddress && !/^bcrt1[a-z0-9]{38,90}$/.test(depositAddress)) {
    throw new Error("--deposit-address must be a regtest bech32/bech32m address");
  }

  return {
    txid: txid.toLowerCase(),
    amountSats: BigInt(amountText),
    opReturn: Uint8Array.from(Buffer.from(opReturnHex, "hex")),
    depositAddress,
    depositVout,
  };
}

function findDepositVout(input: RelayArgs): number {
  if (!input.depositAddress) {
    return 0;
  }
  const depositTx = JSON.parse(bitcoinCli(`gettransaction ${input.txid} true true`));
  const decoded = depositTx.decoded ?? JSON.parse(bitcoinCli(`decoderawtransaction ${depositTx.hex}`));
  const output = decoded.vout.find((candidate: any) => {
    const valueSats = BigInt(Math.round(Number(candidate.value) * 1e8));
    return candidate.scriptPubKey?.address === input.depositAddress && valueSats === input.amountSats;
  });
  if (!output) {
    throw new Error("Could not find matching BTC deposit output in regtest transaction");
  }
  return Number(output.n);
}

async function rebuildTree(): Promise<CommitmentTreeIndex> {
  const eventTree = await rebuildTreeFromSuiEvents().catch((error) => {
    console.warn(`Failed to rebuild Sui tree from events, falling back to relay state: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  });
  return eventTree ?? rebuildTreeFromState();
}

async function rebuildTreeFromSuiEvents(): Promise<CommitmentTreeIndex> {
  const client = new SuiJsonRpcClient({ url: rpcUrl, network: "testnet" });
  const events: any[] = [];
  let cursor: { txDigest: string; eventSeq: string } | null = null;
  for (let page = 0; page < 40; page += 1) {
    const result = await client.queryEvents({
      query: {
        MoveEventModule: {
          package: packageId,
          module: "events",
        },
      },
      cursor,
      limit: 50,
      order: "ascending",
    });
    events.push(...result.data);
    if (!result.hasNextPage || !result.nextCursor) break;
    cursor = result.nextCursor;
  }

  const seen = new Set<number>();
  const commitments: Array<{ leafIndex: number; commitment: bigint; amount: bigint }> = [];
  for (const event of events) {
    const type = event.type.split("::").at(-1) ?? "";
    if (type !== "BtcDepositVerified" && type !== "CommitmentInserted") continue;
    const payload = event.parsedJson as Record<string, unknown> | null;
    const leafIndex = numberField(payload?.leaf_index);
    const commitmentBytes = bytesField(payload?.commitment);
    if (leafIndex == null || !commitmentBytes || seen.has(leafIndex)) continue;
    seen.add(leafIndex);
    commitments.push({
      leafIndex,
      commitment: bytesToBigintLE(commitmentBytes),
      amount: bigintField(payload?.amount_sats) ?? 0n,
    });
  }
  commitments.sort((a, b) => a.leafIndex - b.leafIndex);

  const tree = new CommitmentTreeIndex();
  for (const item of commitments) {
    tree.addCommitment(item.commitment, item.amount);
  }
  return tree;
}

function rebuildTreeFromState(): CommitmentTreeIndex {
  const tree = new CommitmentTreeIndex();
  const prior = (readState() as any).suiDepositRelayCommitments as Array<{ commitment: string; amountSats: string }> | undefined;
  for (const item of prior ?? []) {
    if (!/^[0-9a-fA-F]{64}$/.test(item.commitment) || !/^\d+$/.test(item.amountSats)) continue;
    tree.addCommitment(bytesToBigintLE(Uint8Array.from(Buffer.from(item.commitment, "hex"))), BigInt(item.amountSats));
  }
  return tree;
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

function assertSuiSuccess(label: string, result: any) {
  const status = result.effects?.status;
  if (status?.status !== "success") {
    throw new Error(`${label} failed: ${JSON.stringify(status)}`);
  }
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
  const client = new SuiJsonRpcClient({ url: rpcUrl, network: "testnet" });
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

function bytesToBigintBE(bytes: Uint8Array): bigint {
  let result = 0n;
  for (const byte of bytes) result = (result << 8n) | BigInt(byte);
  return result;
}

function bytesToBigintLE(bytes: Uint8Array): bigint {
  let result = 0n;
  for (let i = bytes.length - 1; i >= 0; i -= 1) {
    result = (result << 8n) | BigInt(bytes[i]);
  }
  return result;
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

function reverseHexToBytes(hex: string): Uint8Array {
  return Uint8Array.from(Buffer.from(hex, "hex").reverse());
}

function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}
