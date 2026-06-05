#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import {
  CommitmentTreeIndex,
  computeJoinSplitCommitmentSync,
  initPoseidon,
} from "@utxopia/sdk";
import { bitcoinCli, stripWitnessData, waitForEsplora, waitForTxIndexed } from "./lib/regtest-helpers";
import {
  findCreatedObject,
  objectRefFromChange,
  readState,
  requireState,
  sharedRefFromChange,
  writeState,
} from "./shared";
import { executeBuiltTransaction } from "./signing";

const ESPLORA_URL = process.env.ESPLORA_URL ?? "http://localhost:3002/regtest/api";
const ZKBTC_TOKEN_ID = 0x7a627463n;
const REGTEST_NETWORK = 2;
const MAX_HEADER_BATCH = 10;

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
const adminCap = requireState(state.adminCap, "adminCap");
const commitmentTree = requireState(state.commitmentTree, "commitmentTree");
const btcDepositRegistry = requireState(state.btcDepositRegistry, "btcDepositRegistry");
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const client = new SuiJsonRpcClient({ url: rpcUrl, network: "testnet" });

const depositVout = args.depositVout ?? findDepositVout(args);
const deposit = readDepositTransaction(args.txid);
const block = readBlock(deposit.blockhash);
const txIndex = findTxIndex(block, args.txid);
const proof = buildMerkleProof(block.txids, txIndex);
assertMerkleRoot(proof.root, block.merkleRoot);
assertTxidMatches(deposit.legacyRawTx, args.txid);

await ensureLightClient(block);
const lightClient = requireState(state.lightClient, "lightClient");

const npk = bytesToBigintBE(args.opReturn.slice(32, 64));
const commitment = computeJoinSplitCommitmentSync(npk, ZKBTC_TOKEN_ID, args.amountSats);
const tree = await rebuildTree();
tree.addCommitment(commitment, args.amountSats);
const offchainPoseidonRoot = tree.getRoot();

const relayTx = new Transaction();
const inclusion = relayTx.moveCall({
  target: `${packageId}::btc_light_client::verify_tx_inclusion`,
  arguments: [
    shared(relayTx, lightClient, false),
    relayTx.pure.vector("u8", reverseHexToBytes(block.hash)),
    relayTx.pure.vector("u8", reverseHexToBytes(args.txid)),
    relayTx.pure.u32(txIndex),
    relayTx.pure("vector<vector<u8>>", proof.siblings.map((bytes) => Array.from(bytes))),
    relayTx.pure.u64(proof.pathBits.toString()),
  ],
});
relayTx.moveCall({
  target: `${packageId}::btc_deposit::complete_deposit`,
  arguments: [
    shared(relayTx, pool, true),
    shared(relayTx, btcDepositRegistry, true),
    shared(relayTx, requireState(state.utxoSet, "utxoSet"), true),
    shared(relayTx, commitmentTree, true),
    inclusion,
    relayTx.pure.vector("u8", deposit.legacyRawTx),
    relayTx.pure.vector("u8", new Uint8Array()),
    relayTx.pure.bool(true),
  ],
});
const result = await executeBuiltTransaction(relayTx);
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
  blockHash: block.hash,
  txIndex,
  pathBits: proof.pathBits.toString(),
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

interface DepositTransaction {
  txid: string;
  blockhash: string;
  decoded: any;
  legacyRawTx: Uint8Array;
}

interface BlockContext {
  hash: string;
  height: number;
  previousblockhash: string;
  merkleroot: string;
  merkleRoot: Uint8Array;
  txids: string[];
  rawHeader: Uint8Array;
}

function readDepositTransaction(txid: string): DepositTransaction {
  const walletTx = JSON.parse(bitcoinCli(`gettransaction ${txid} true true`));
  if (!walletTx.blockhash) {
    throw new Error(`BTC transaction ${txid} is not confirmed`);
  }
  if (!walletTx.hex || !walletTx.decoded) {
    throw new Error(`BTC transaction ${txid} is missing hex/decoded data`);
  }
  return {
    txid,
    blockhash: walletTx.blockhash,
    decoded: walletTx.decoded,
    legacyRawTx: Uint8Array.from(stripWitnessData(Buffer.from(walletTx.hex, "hex"))),
  };
}

function readBlock(hash: string): BlockContext {
  const block = JSON.parse(bitcoinCli(`getblock ${hash} 2`));
  const rawHeader = Uint8Array.from(Buffer.from(bitcoinCli(`getblockheader ${hash} false`), "hex"));
  const txids = (block.tx ?? []).map((tx: any) => String(tx.txid));
  if (!Number.isInteger(block.height) || !block.previousblockhash || txids.length === 0) {
    throw new Error(`Unexpected Bitcoin block response for ${hash}`);
  }
  return {
    hash: block.hash,
    height: Number(block.height),
    previousblockhash: block.previousblockhash,
    merkleroot: block.merkleroot,
    merkleRoot: reverseHexToBytes(block.merkleroot),
    txids,
    rawHeader,
  };
}

function findTxIndex(block: BlockContext, txid: string): number {
  const index = block.txids.findIndex((candidate) => candidate === txid);
  if (index < 0) {
    throw new Error(`BTC transaction ${txid} was not found in block ${block.hash}`);
  }
  return index;
}

function buildMerkleProof(txids: string[], txIndex: number): {
  siblings: Uint8Array[];
  pathBits: bigint;
  root: Uint8Array;
} {
  let level = txids.map(reverseHexToBytes);
  let index = txIndex;
  let pathBits = 0n;
  const siblings: Uint8Array[] = [];

  while (level.length > 1) {
    const siblingIndex = index % 2 === 0
      ? Math.min(index + 1, level.length - 1)
      : index - 1;
    siblings.push(level[siblingIndex]);
    if (index % 2 === 1) {
      pathBits |= 1n << BigInt(siblings.length - 1);
    }

    const next: Uint8Array[] = [];
    for (let i = 0; i < level.length; i += 2) {
      const left = level[i];
      const right = level[i + 1] ?? left;
      next.push(hash256(concatBytes(left, right)));
    }
    level = next;
    index = Math.floor(index / 2);
  }

  return { siblings, pathBits, root: level[0] };
}

function assertMerkleRoot(actual: Uint8Array, expected: Uint8Array) {
  if (toHex(actual) !== toHex(expected)) {
    throw new Error(`Merkle proof root mismatch: got ${toHex(actual)}, expected ${toHex(expected)}`);
  }
}

function assertTxidMatches(rawTx: Uint8Array, txid: string) {
  const actual = toHex(hash256(rawTx));
  const expected = toHex(reverseHexToBytes(txid));
  if (actual !== expected) {
    throw new Error(`Legacy raw tx hash mismatch: got ${actual}, expected ${expected}`);
  }
}

async function ensureLightClient(block: BlockContext) {
  if (!state.lightClient) {
    const parent = readBlock(block.previousblockhash);
    const initTx = new Transaction();
    initTx.moveCall({
      target: `${packageId}::btc_light_client::initialize`,
      arguments: [
        initTx.pure.u8(REGTEST_NETWORK),
        initTx.pure.vector("u8", parent.rawHeader),
        initTx.pure.u64(parent.height),
        initTx.pure.u256(BigInt(`0x${JSON.parse(bitcoinCli(`getblock ${parent.hash} 1`)).chainwork}`)),
        initTx.pure.u32(Number.parseInt(JSON.parse(bitcoinCli(`getblock ${parent.hash} 1`)).bits, 16)),
        initTx.pure.u32(Number(JSON.parse(bitcoinCli(`getblock ${parent.hash} 1`)).time)),
      ],
    });
    const result = await executeBuiltTransaction(initTx);
    assertSuiSuccess("Sui BTC light-client init", result);
    const changes = result.objectChanges ?? [];
    state.lightClient = sharedRefFromChange(findCreatedObject(changes, "::btc_light_client::LightClient"));
    state.lightClientAdminCap = objectRefFromChange(findCreatedObject(changes, "::btc_light_client::LightClientAdminCap"));
    writeState(state);
  }

  await submitHeadersThrough(block.height);
  await bindPoolIfNeeded();
}

async function submitHeadersThrough(height: number) {
  const light = requireState(state.lightClient, "lightClient");
  const object = await client.getObject({ id: light.objectId, options: { showContent: true } });
  const fields = (object.data?.content as any)?.fields;
  const tipHeight = Number(fields?.tip_height ?? fields?.tipHeight ?? 0);
  if (!Number.isInteger(tipHeight)) {
    throw new Error(`Could not read Sui BTC light-client tip height for ${light.objectId}`);
  }
  if (tipHeight >= height) {
    return;
  }

  for (let start = tipHeight + 1; start <= height; start += MAX_HEADER_BATCH) {
    const end = Math.min(height, start + MAX_HEADER_BATCH - 1);
    const headers: Uint8Array[] = [];
    for (let h = start; h <= end; h += 1) {
      const hash = bitcoinCli(`getblockhash ${h}`);
      headers.push(Uint8Array.from(Buffer.from(bitcoinCli(`getblockheader ${hash} false`), "hex")));
    }

    const tx = new Transaction();
    tx.moveCall({
      target: `${packageId}::btc_light_client::submit_headers`,
      arguments: [
        shared(tx, light, true),
        tx.pure.vector("u8", concatBytes(...headers)),
        tx.object.clock(),
      ],
    });
    const result = await executeBuiltTransaction(tx);
    assertSuiSuccess(`Sui BTC header submit ${start}-${end}`, result);
  }
}

async function bindPoolIfNeeded() {
  const object = await client.getObject({ id: pool.objectId, options: { showContent: true } });
  const fields = (object.data?.content as any)?.fields;
  const tx = new Transaction();
  let changed = false;

  if (!fields?.light_client_id) {
    tx.moveCall({
      target: `${packageId}::pool::set_light_client_id`,
      arguments: [
        tx.object(adminCap.objectId),
        shared(tx, pool, true),
        tx.pure.address(requireState(state.lightClient, "lightClient").objectId),
      ],
    });
    changed = true;
  }

  if (!fields?.btc_pool_script) {
    tx.moveCall({
      target: `${packageId}::pool::set_btc_pool_script`,
      arguments: [
        tx.object(adminCap.objectId),
        shared(tx, pool, true),
        tx.pure.vector("u8", ikaVaultP2trScript()),
      ],
    });
    changed = true;
  }

  if (!changed) {
    return;
  }

  const result = await executeBuiltTransaction(tx);
  assertSuiSuccess("Sui pool BTC bindings", result);
  const adminChange = (result.objectChanges ?? []).find((change: any) =>
    change.objectId === adminCap.objectId && (change.type === "mutated" || change.type === "created")
  );
  state.adminCap = objectRefFromChange(adminChange) ?? state.adminCap;
  writeState(state);
}

function ikaVaultP2trScript(): Uint8Array {
  const xonly = state.ikaSui?.dWalletXOnlyPubkey ?? state.ika?.dwalletXOnlyPubkey;
  if (!xonly || !/^[0-9a-fA-F]{64}$/.test(xonly)) {
    throw new Error("ika dWallet x-only pubkey missing from Sui state; cannot bind BTC pool script");
  }
  return Uint8Array.from(Buffer.concat([Buffer.from([0x51, 0x20]), Buffer.from(xonly, "hex")]));
}

function shared(tx: Transaction, ref: { objectId: string; initialSharedVersion: string | number }, mutable: boolean) {
  return tx.sharedObjectRef({
    objectId: ref.objectId,
    initialSharedVersion: ref.initialSharedVersion,
    mutable,
  });
}

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

function hash256(bytes: Uint8Array): Uint8Array {
  const first = createHash("sha256").update(bytes).digest();
  return Uint8Array.from(createHash("sha256").update(first).digest());
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  return Uint8Array.from(Buffer.concat(parts.map((part) => Buffer.from(part))));
}
