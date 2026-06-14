#!/usr/bin/env bun
import { randomBytes } from "node:crypto";
import { sha256 } from "@noble/hashes/sha2.js";
import { schnorr } from "@noble/curves/secp256k1.js";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Curve, SignatureAlgorithm } from "@ika.xyz/sdk";
import {
  BN254_FIELD_PRIME,
  buildDepositOpReturn,
  bytesToBigint,
  computeBoundParamsHash,
  DEPOSIT_BITCOIN_NETWORK,
  DEPOSIT_DESTINATION_CHAIN,
  eddsaGetPubKey,
  eddsaPoseidonSign,
  poseidonHashSync,
} from "@utxopia/sdk";
import { UTXOpiaSuiAdapter } from "@utxopia/sdk/sui";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";
import {
  createOpReturnTx,
  getNewAddress,
  mineBlocks,
  waitForEsplora,
  waitForTxIndexed,
  bitcoinCli,
  fetchMerkleProof,
  stripWitnessData,
} from "./lib/regtest-helpers";
import {
  concatBytes,
  fieldToSuiBytes,
  hexToBytes,
  reverseHexToBytes,
  to0xHex as toHex,
} from "./lib/bytes";
import { assertSuiSuccess } from "./lib/sui-tx";
import { Transaction } from "@mysten/sui/transactions";
import { readState, requireState, writeState, findCreatedObject, objectRefFromChange, sharedRefFromChange } from "./shared";
import { cleanupProof, exportSuiProof, generateProof, verifyProof } from "./test-flow/proof-artifacts";
import { loadRegtestConfig } from "./test-flow/regtest-config";
import { executeTransactionKind, executeBuiltTransaction } from "./signing";
import { loadOrCreateIkaUserShareKeys } from "./ika-user-share-keys";

const REGTEST_CONFIG = loadRegtestConfig();
const ESPLORA_URL = process.env.ESPLORA_URL ?? REGTEST_CONFIG.esploraUrl;
const TREE_DEPTH = 16;
const ZKBTC_TOKEN_ID = 0x7a627463n;
const CIRCUIT = "joinsplit_1x1";

const state = readState();
const SUI_RPC_URL = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const commitmentTree = requireState(state.commitmentTree, "commitmentTree");
const btcDepositRegistry = requireState(state.btcDepositRegistry, "btcDepositRegistry");
const utxoSet = requireState(state.utxoSet, "utxoSet");
let lightClient = state.lightClient;
const nullifierRegistry = requireState(state.nullifierRegistry, "nullifierRegistry");
const redemptionQueue = requireState(state.redemptionQueue, "redemptionQueue");
const redemptionCap = requireState(state.redemptionCap, "redemptionCap");
const verifyingKeyRegistry = requireState(state.verifyingKeyRegistry, "verifyingKeyRegistry");
const vk = requireState(state.vk?.[CIRCUIT], `${CIRCUIT} vk`);

const amount = BigInt(process.env.UTXOPIA_SUI_REGTEST_AMOUNT_SATS ?? "25000");
const minerFee = BigInt(process.env.UTXOPIA_SUI_REGTEST_WITHDRAW_FEE_SATS ?? "1000");
const withdrawalSignerMode = process.env.UTXOPIA_SUI_WITHDRAW_SIGNER_MODE ?? "relayer";
if (amount <= minerFee + 546n) {
  throw new Error("UTXOPIA_SUI_REGTEST_AMOUNT_SATS must exceed fee plus dust threshold");
}
if (withdrawalSignerMode !== "relayer" && withdrawalSignerMode !== "ika") {
  throw new Error("UTXOPIA_SUI_WITHDRAW_SIGNER_MODE must be `relayer` or `ika`");
}
const ikaSigningConfig = withdrawalSignerMode === "ika" ? requireIkaSuiSigningConfig() : null;

let adapter: UTXOpiaSuiAdapter;
let regtestPoolBtcAddress = process.env.UTXOPIA_SUI_REGTEST_POOL_BTC_ADDRESS ?? (state as any).regtestPoolBtcAddress;

await runRegtestFlow();

function createAdapter(cap: typeof redemptionCap) {
  return new UTXOpiaSuiAdapter({
    rpcUrl: SUI_RPC_URL,
    packageId,
    poolObjectId: pool.objectId,
    poolInitialSharedVersion: pool.initialSharedVersion,
    commitmentTreeObjectId: commitmentTree.objectId,
    commitmentTreeInitialSharedVersion: commitmentTree.initialSharedVersion,
    btcDepositRegistryObjectId: btcDepositRegistry.objectId,
    btcDepositRegistryInitialSharedVersion: btcDepositRegistry.initialSharedVersion,
    utxoSetObjectId: utxoSet.objectId,
    utxoSetInitialSharedVersion: utxoSet.initialSharedVersion,
    lightClientObjectId: lightClient.objectId,
    lightClientInitialSharedVersion: lightClient.initialSharedVersion,
    nullifierRegistryObjectId: nullifierRegistry.objectId,
    nullifierRegistryInitialSharedVersion: nullifierRegistry.initialSharedVersion,
    redemptionQueueObjectId: redemptionQueue.objectId,
    redemptionQueueInitialSharedVersion: redemptionQueue.initialSharedVersion,
    redemptionCapObjectId: redemptionCap.objectId,
    redemptionCapVersion: cap.version,
    redemptionCapDigest: cap.digest,
    verifyingKeyRegistryObjectId: verifyingKeyRegistry.objectId,
    verifyingKeyRegistryInitialSharedVersion: verifyingKeyRegistry.initialSharedVersion,
  });
}

async function refreshCapAdapter() {
  // redemptionCap is an owned object; each cap-using call bumps its version. Re-fetch + rebuild.
  const c = new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" });
  const o = await c.getObject({ id: redemptionCap.objectId });
  adapter = createAdapter({ objectId: redemptionCap.objectId, version: o.data!.version, digest: o.data!.digest } as typeof redemptionCap);
}

async function runRegtestFlow() {
  lightClient = await ensureLightClientInitialized();
  adapter = createAdapter(redemptionCap);

  await waitForEsplora(ESPLORA_URL, 30_000);

  const note = await buildJoinSplitNote(amount);
  const deposit = await createDirectDeposit(note.inputNpk, amount);

  console.log("Submitting Sui SPV BTC deposit completion...");
  const depositProof = await fetchMerkleProof(deposit.depositTxid, ESPLORA_URL);
  const depositBlockHash = btc(`getblockhash ${depositProof.block_height}`);
  await submitHeadersThrough(depositProof.block_height);
  const shieldTx = await adapter.buildBtcDepositTransaction({
    blockHash: reverseHexToBytes(depositBlockHash),
    sweepTxid: reverseHexToBytes(deposit.depositTxid),
    txIndex: depositProof.pos,
    merkleSiblings: depositProof.merkle.map(reverseHexToBytes),
    pathBits: BigInt(depositProof.pos),
    sweepRawTx: deposit.rawTx,
    directToPool: true,
  });
  const shieldResult = await executeTransactionKind(shieldTx.bytes);
  assertSuiSuccess("shield", shieldResult);

  const redeemFrontier = await readTreeFrontier();

  console.log("Submitting Sui private transfer proof...");
  const transactTx = await adapter.buildTransactTransaction({
    inputNotes: [{
      commitment: toHex(fieldToSuiBytes(note.inputCommitment)),
      nullifier: toHex(note.nullifierBytes),
      tokenId: "zkbtc",
      leafIndex: 0,
    }],
    outputs: [{
      recipient: "sui-regtest",
      tokenId: "zkbtc",
      amount,
    }],
    proof: note.proofPoints,
    boundParamsHash: toHex(fieldToSuiBytes(note.boundParamsHash)),
    vkHash: hexToBytes(vk.vkHash),
    publicInputs: note.publicInputs,
    proofPoints: note.proofPoints,
    commitmentsOut: [note.commitmentOutBytes],
    stealthData: [note.stealthBlob],
  });
  const transactResult = await executeTransactionKind(transactTx.bytes);
  assertSuiSuccess("transact", transactResult);

  if (process.env.UTXOPIA_SUI_DO_REDEEM === "1") {
    await runRedeemAndWithdraw(note, deposit, redeemFrontier);
  }

  (state as any).lastSuiRegtestFlow = {
    amountSats: amount.toString(),
    depositTxid: deposit.depositTxid,
    shieldTxDigest: shieldResult.digest,
    transactTxDigest: transactResult.digest,
    status: "deposit_and_transact_complete",
    redeemStatus: "disabled_until_real_redeem_proof_fixture",
  };
  writeState(state);

  console.log(JSON.stringify({
    amountSats: amount.toString(),
    btc: {
      depositTxid: deposit.depositTxid,
      depositVout: deposit.depositVout,
      depositAmountSats: deposit.amountSats.toString(),
      poolAddress: deposit.poolAddress,
    },
    sui: {
      shieldTxDigest: shieldResult.digest,
      shieldStatus: shieldResult.effects?.status,
      transactTxDigest: transactResult.digest,
      transactStatus: transactResult.effects?.status,
    },
    limitations: [
      "Sui BTC deposit completion is SPV-checked in one PTB: btc_light_client::verify_tx_inclusion feeds btc_deposit::complete_deposit.",
      "BTC redemption is intentionally not run here until this script builds a second proof-checked redeem fixture for the output note.",
    ],
  }, null, 2));

  cleanupProof(note.tmpDir);
}

async function createDirectDeposit(inputNpk: bigint, depositAmount: bigint) {
  console.log("Creating direct regtest BTC deposit to pool with compact OP_RETURN...");
  const ephPub = randomBytes(32);
  // On-chain complete_deposit parses note_public_key via field_from_be_bytes (big-endian),
  // so the OP_RETURN npk must be big-endian (fieldToSuiBytes is little-endian for Groth16 inputs).
  const npkBeBytes = Uint8Array.from(Buffer.from(fieldToSuiBytes(inputNpk)).reverse());
  const opReturnPayload = buildSuiDepositOpReturnPayload(ephPub, npkBeBytes);
  const payloadHex = Buffer.from(opReturnPayload).toString("hex");
  const poolAddress = getRegtestPoolBtcAddress();
  const depositTxid = createOpReturnTx(poolAddress, Number(depositAmount), payloadHex);
  const minerAddress = getNewAddress("bech32m");
  mineBlocks(6, minerAddress);
  await waitForTxIndexed(depositTxid, ESPLORA_URL);

  const depositTx = JSON.parse(btc(`gettransaction ${depositTxid} true true`));
  const decoded = depositTx.decoded ?? JSON.parse(btc(`decoderawtransaction ${depositTx.hex}`));
  const depositOutput = decoded.vout.find((out: any) => out.scriptPubKey?.address === poolAddress);
  if (!depositOutput) {
    throw new Error("Could not find direct pool deposit output");
  }
  const outputAmountSats = BigInt(Math.round(Number(depositOutput.value) * 1e8));
  if (outputAmountSats !== depositAmount) {
    throw new Error(`Deposit output amount ${outputAmountSats} does not match note amount ${depositAmount}`);
  }

  return {
    depositTxid,
    depositVout: Number(depositOutput.n),
    amountSats: outputAmountSats,
    poolAddress,
    opReturnPayload,
    rawTx: Uint8Array.from(stripWitnessData(Buffer.from(depositTx.hex, "hex"))),
  };
}

function buildSuiDepositOpReturnPayload(ephemeralPubkey: Uint8Array, notePublicKey: Uint8Array): Uint8Array {
  const tagInput = concatBytes([
    new TextEncoder().encode("UTXOPIA_SUI"),
    suiAddressToBytes(pool.objectId),
    suiAddressToBytes(commitmentTree.objectId),
  ]);
  return buildDepositOpReturn(ephemeralPubkey, notePublicKey, {
    destinationChain: DEPOSIT_DESTINATION_CHAIN.SUI,
    bitcoinNetwork: DEPOSIT_BITCOIN_NETWORK.REGTEST,
    poolTag: sha256(tagInput).slice(0, 8),
  });
}

function suiAddressToBytes(value: string): Uint8Array {
  const hex = value.startsWith("0x") ? value.slice(2) : value;
  if (hex.length > 64) {
    throw new Error(`invalid Sui address: ${value}`);
  }
  return hexToBytes(hex.padStart(64, "0"));
}

async function broadcastWithdrawal(depositTxid: string, depositVout: number, inputAmountSats: bigint, sendAmountSats: bigint) {
  console.log("Broadcasting regtest BTC withdrawal from direct pool deposit UTXO with the local relayer signer...");
  const destinationAddress = process.env.UTXOPIA_SUI_REGTEST_WITHDRAW_BTC_ADDRESS ?? getNewAddress("bech32m");
  const poolChangeAddress = process.env.UTXOPIA_SUI_REGTEST_POOL_BTC_ADDRESS ?? getNewAddress("bech32m");
  const changeSats = inputAmountSats - sendAmountSats - minerFee;
  if (sendAmountSats <= 546n) {
    throw new Error(`Withdrawal output ${sendAmountSats} sats is dust`);
  }
  if (changeSats < 0n) {
    throw new Error("Withdrawal amount plus fee exceeds swept input amount");
  }

  const outputs: Record<string, number> = {
    [destinationAddress]: Number(sendAmountSats) / 1e8,
  };
  if (changeSats > 546n) {
    outputs[poolChangeAddress] = Number(changeSats) / 1e8;
  }

  const rawTxHex = btc(`-named createrawtransaction inputs='[{"txid":"${depositTxid}","vout":${depositVout}}]' outputs='${JSON.stringify(outputs)}'`);
  const signed = JSON.parse(btc(`signrawtransactionwithwallet ${rawTxHex}`));
  if (!signed.complete) {
    throw new Error("Failed to sign withdrawal transaction");
  }
  const withdrawTxid = btc(`sendrawtransaction ${signed.hex}`);
  mineBlocks(6);
  await waitForTxIndexed(withdrawTxid, ESPLORA_URL);

  return {
    destinationAddress,
    withdrawTxid,
    rawTxHex: signed.hex as string,
  };
}

async function buildJoinSplitNote(noteAmount: bigint) {
  // 72-byte stealth blob (ephemeral_pub 32 + encrypted_amount 8 + view_tag etc.)
  // bound into the proof and emitted by transact as StealthAnnounced.
  const stealthBlob = Uint8Array.from(randomBytes(72));
  const seed = randomBytes(32);
  const publicKey = await eddsaGetPubKey(seed);
  const nullifyingKey = randomFieldElement();
  const mpk = poseidonHashSync([publicKey.x, publicKey.y, nullifyingKey]);
  const inputRandom = randomFieldElement();
  const inputNpk = poseidonHashSync([mpk, inputRandom]);
  const inputCommitment = poseidonHashSync([inputNpk, ZKBTC_TOKEN_ID, noteAmount]);
  // The note will be inserted by complete_deposit at the tree's current next_index.
  // Reconstruct the real path against the live tree (not a single-leaf-0 approximation).
  const merkle = await buildMerkleProofForLeaf(inputCommitment);
  const outputRandom = randomFieldElement();
  const outputNpk = poseidonHashSync([mpk, outputRandom]);
  const outputCommitment = poseidonHashSync([outputNpk, ZKBTC_TOKEN_ID, noteAmount]);
  const nullifier = poseidonHashSync([nullifyingKey, BigInt(merkle.index)]);
  const boundParamsHash = computeBoundParamsHash({
    treeNumber: 0,
    unshieldAddress: null,
    chainId: BigInt(process.env.UTXOPIA_SUI_CHAIN_ID ?? "784"),
    stealthDataHash: sha256(stealthBlob),
  });
  const msgHash = poseidonHashSync([merkle.root, boundParamsHash, nullifier, outputCommitment]);
  const signature = await eddsaPoseidonSign(seed, msgHash);

  const circuitInputs = {
    merkleRoot: merkle.root.toString(),
    boundParamsHash: boundParamsHash.toString(),
    nullifiers: [nullifier.toString()],
    commitmentsOut: [outputCommitment.toString()],
    token: ZKBTC_TOKEN_ID.toString(),
    publicKey: [publicKey.x.toString(), publicKey.y.toString()],
    signature: signature.map((item) => item.toString()),
    nullifyingKey: nullifyingKey.toString(),
    randomIn: [inputRandom.toString()],
    valueIn: [noteAmount.toString()],
    leavesIndices: [String(merkle.index)],
    pathElements: [merkle.siblings.map((item) => item.toString())],
    npkOut: [outputNpk.toString()],
    valueOut: [noteAmount.toString()],
  };

  console.log(`Generating ${CIRCUIT} Groth16 proof...`);
  const proofArtifacts = generateProof(CIRCUIT, circuitInputs, { tmpPrefix: "regtest-flow" });
  console.log("Verifying generated proof with snarkjs...");
  verifyProof(CIRCUIT, proofArtifacts.proofPath, proofArtifacts.publicPath);
  console.log("Exporting proof to Sui native Groth16 bytes...");
  const exportedProof = exportSuiProof(proofArtifacts.proofPath, proofArtifacts.publicPath);

  // The Sui Groth16 verifier consumes the exporter's little-endian public inputs as-is;
  // the contract's assert_public_input_at/extract_public_input reverse each chunk to
  // big-endian to compare against field_to_be_bytes targets.
  const publicInputs = hexToBytes(exportedProof.publicInputs);
  return {
    ...proofArtifacts,
    inputNpk,
    inputCommitment,
    outputCommitment,
    merkle,
    boundParamsHash,
    publicInputs,
    proofPoints: hexToBytes(exportedProof.proofPoints),
    // Secrets needed to later spend (redeem) the transfer's OUTPUT note.
    secrets: { seed, publicKey, nullifyingKey, mpk, outputRandom, outputNpk, value: noteAmount, depositLeafIndex: merkle.index },
    // Targets are compared big-endian on-chain (assert_public_input_at reverses the
    // little-endian public-input chunk); commitment insertion also uses field_from_be_bytes.
    nullifierBytes: Uint8Array.from(publicInputs.slice(64, 96)).reverse(),
    commitmentOutBytes: Uint8Array.from(publicInputs.slice(96, 128)).reverse(),
    stealthBlob,
  };
}

function reversePublicInputChunks(blob: Uint8Array): Uint8Array {
  const out = new Uint8Array(blob.length);
  for (let off = 0; off < blob.length; off += 32) {
    const chunk = blob.slice(off, off + 32);
    out.set(Uint8Array.from(chunk).reverse(), off);
  }
  return out;
}

async function fetchExistingLeaves(): Promise<bigint[]> {
  const body = {
    jsonrpc: "2.0", id: 1, method: "suix_queryEvents",
    params: [{ MoveEventModule: { package: packageId, module: "events" } }, null, 1000, false],
  };
  const res = await fetch(SUI_RPC_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const json = await res.json() as any;
  const byIndex = new Map<number, bigint>();
  for (const e of (json.result?.data ?? [])) {
    if (!String(e.type).endsWith("::CommitmentInserted")) continue;
    const idx = Number(e.parsedJson.leaf_index);
    let v = 0n; // commitment is big-endian 32 bytes
    for (const b of e.parsedJson.commitment as number[]) v = (v << 8n) | BigInt(b);
    byIndex.set(idx, v);
  }
  const leaves: bigint[] = [];
  for (let i = 0; i < byIndex.size; i += 1) {
    if (!byIndex.has(i)) throw new Error(`missing CommitmentInserted event for leaf ${i}`);
    leaves.push(byIndex.get(i)!);
  }
  return leaves;
}

// Read the commitment tree's incremental-merkle frontier (filled_subtrees) + next_index.
// Robust against event-indexer lag (unlike reconstructing from CommitmentInserted events).
async function readTreeFrontier(): Promise<{ nextIndex: number; frontier: bigint[] }> {
  const c = new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" });
  const obj = await c.getObject({ id: commitmentTree.objectId, options: { showContent: true } });
  const f = (obj.data?.content as any)?.fields;
  return { nextIndex: Number(f.next_index ?? f.nextIndex), frontier: (f.filled_subtrees ?? f.filledSubtrees).map((x: string) => BigInt(x)) };
}

// Path for inserting `leaf` at the rightmost position `index` given the frontier, matching
// commitment_tree::insert (bit 0 → sibling=zeroHash[level] on the right; bit 1 → sibling=frontier[level] on the left).
function buildRightmostPath(leaf: bigint, frontier: bigint[], index: number) {
  const zero = computeZeroHashes();
  const siblings: bigint[] = [];
  let node = leaf;
  for (let i = 0; i < TREE_DEPTH; i += 1) {
    const bit = (index >> i) & 1;
    const sib = bit ? frontier[i] : zero[i];
    siblings.push(sib);
    node = bit ? poseidonHashSync([sib, node]) : poseidonHashSync([node, sib]);
  }
  return { root: node, siblings, index };
}

async function buildMerkleProofForLeaf(leaf: bigint) {
  const { nextIndex, frontier } = await readTreeFrontier();
  return buildRightmostPath(leaf, frontier, nextIndex);
}

function buildSingleLeafProof(leaf: bigint) {
  const zeroHashes = computeZeroHashes();
  const siblings = zeroHashes.slice(0, TREE_DEPTH);
  const indices = new Array(TREE_DEPTH).fill(0);
  let root = leaf;
  for (let level = 0; level < TREE_DEPTH; level += 1) {
    root = poseidonHashSync([root, zeroHashes[level]]);
  }
  return { root, siblings, indices };
}

function computeZeroHashes(): bigint[] {
  const zeroHashes = [0n];
  for (let i = 1; i <= TREE_DEPTH; i += 1) {
    zeroHashes[i] = poseidonHashSync([zeroHashes[i - 1], zeroHashes[i - 1]]);
  }
  return zeroHashes;
}

function randomFieldElement(): bigint {
  return bytesToBigint(randomBytes(32)) % BN254_FIELD_PRIME;
}

function findEventField(events: any[] | undefined, typeSuffix: string, field: string): string | undefined {
  const event = events?.find((candidate) => typeof candidate.type === "string" && candidate.type.endsWith(typeSuffix));
  const value = event?.parsedJson?.[field];
  return value === undefined ? undefined : String(value);
}

function btc(cmd: string): string {
  return bitcoinCli(cmd);
}

interface IkaSuiSigningConfig {
  network: "testnet" | "mainnet";
  dWalletId: string;
  dWalletCapObjectId: string;
  networkEncryptionKeyId: string;
  ikaCoinObjectId: string;
  suiCoinObjectId: string;
  encryptedUserSecretKeyShareId: string;
}

function requireIkaSuiSigningConfig(): IkaSuiSigningConfig {
  const ikaState = state.ikaSui ?? {};
  const config = {
    network: (process.env.UTXOPIA_SUI_IKA_NETWORK || ikaState.network || "testnet") as "testnet" | "mainnet",
    dWalletId: process.env.UTXOPIA_SUI_IKA_DWALLET_ID || ikaState.dWalletId || "",
    dWalletCapObjectId: process.env.UTXOPIA_SUI_IKA_DWALLET_CAP_ID || ikaState.dWalletCapObjectId || "",
    networkEncryptionKeyId:
      process.env.UTXOPIA_SUI_IKA_NETWORK_ENCRYPTION_KEY_ID || ikaState.networkEncryptionKeyId || "",
    ikaCoinObjectId: process.env.UTXOPIA_SUI_IKA_COIN_ID || ikaState.ikaCoinObjectId || "",
    suiCoinObjectId: process.env.UTXOPIA_SUI_IKA_SUI_COIN_ID || ikaState.suiCoinObjectId || "",
    encryptedUserSecretKeyShareId:
      process.env.UTXOPIA_SUI_IKA_ENCRYPTED_USER_SECRET_KEY_SHARE_ID ||
      ikaState.encryptedUserSecretKeyShareId ||
      "",
  };
  const missing = Object.entries(config)
    .filter(([key, value]) => key !== "network" && !value)
    .map(([key]) => key);
  if (missing.length > 0) {
    throw new Error(
      [
        `Sui Ika signing mode is missing: ${missing.join(", ")}`,
        "Fund the relayer with Coin<IKA> and make sure it owns a dWallet cap, then run:",
        "  UTXOPIA_SUI_IKA_AUTO_SELECT=1 bun run sui:ika:discover",
        "You can also provide explicit UTXOPIA_SUI_IKA_* object ID env vars.",
      ].join("\n"),
    );
  }
  if (config.network !== "testnet" && config.network !== "mainnet") {
    throw new Error("UTXOPIA_SUI_IKA_NETWORK must be `testnet` or `mainnet`");
  }
  return config;
}

async function submitNativeIkaSigning(message: Uint8Array, config: IkaSuiSigningConfig) {
  const ikaAdapter = new UTXOpiaSuiIkaAdapter({
    rpcUrl: SUI_RPC_URL,
    network: config.network,
    dWalletId: config.dWalletId,
    dWalletCapObjectId: config.dWalletCapObjectId,
    networkEncryptionKeyId: config.networkEncryptionKeyId,
    ikaCoinObjectId: config.ikaCoinObjectId,
    suiCoinObjectId: config.suiCoinObjectId,
    encryptedUserSecretKeyShareId: config.encryptedUserSecretKeyShareId,
    userShareEncryptionKeys: await loadOrCreateIkaUserShareKeys(),
    suiPaymentReturnAddress: process.env.UTXOPIA_SUI_RELAYER_ADDRESS || state.relayer?.address,
  });
  const ikaClient = ikaAdapter.createClient();
  await ikaClient.initialize();

  console.log("Requesting Sui Ika global Taproot presign...");
  const presignTx = await ikaAdapter.buildRequestGlobalTaprootPresignTransaction();
  const presignRequestResult = await executeTransactionKind(presignTx.bytes);
  assertSuiSuccess("Ika global Taproot presign request", presignRequestResult);
  const presignId = findCreatedObjectId(presignRequestResult, "coordinator_inner::PresignSession");
  if (!presignId) {
    throw new Error(`Ika presign request ${presignRequestResult.digest} did not create a PresignSession`);
  }

  const waitOptions = {
    timeout: Number(process.env.UTXOPIA_SUI_IKA_WAIT_TIMEOUT_MS ?? "120000"),
    interval: Number(process.env.UTXOPIA_SUI_IKA_WAIT_INTERVAL_MS ?? "1000"),
    maxInterval: Number(process.env.UTXOPIA_SUI_IKA_WAIT_MAX_INTERVAL_MS ?? "5000"),
  };
  console.log(`Waiting for Sui Ika presign ${presignId} to complete...`);
  await ikaClient.getPresignInParticularState(presignId, "Completed", waitOptions);

  console.log("Requesting Sui Ika Taproot signature...");
  const signTx = await ikaAdapter.buildTaprootSignWithPublicSharesTransaction({
    presignId,
    message,
  });
  const signRequestResult = await executeTransactionKind(signTx.bytes);
  assertSuiSuccess("Ika Taproot sign request", signRequestResult);
  const signId = findCreatedObjectId(signRequestResult, "coordinator_inner::SignSession");
  if (!signId) {
    throw new Error(`Ika sign request ${signRequestResult.digest} did not create a SignSession`);
  }

  console.log(`Waiting for Sui Ika signature ${signId} to complete...`);
  const sign = await ikaClient.getSignInParticularState(
    signId,
    Curve.SECP256K1,
    SignatureAlgorithm.Taproot,
    "Completed",
    waitOptions,
  );

  return {
    dWalletId: config.dWalletId,
    dWalletCapObjectId: config.dWalletCapObjectId,
    presignRequestTxDigest: presignRequestResult.digest,
    presignId,
    signRequestTxDigest: signRequestResult.digest,
    signId,
    signatureHex: extractCompletedSignatureHex(sign),
  };
}

function findCreatedObjectId(result: any, objectTypeSuffix: string): string | undefined {
  const created = result.objectChanges?.find((change: any) =>
    change.type === "created" &&
    typeof change.objectType === "string" &&
    change.objectType.endsWith(objectTypeSuffix)
  );
  return created?.objectId;
}

function extractCompletedSignatureHex(sign: any): string {
  const signature =
    sign?.state?.Completed?.signature ??
    sign?.state?.completed?.signature ??
    sign?.state?.fields?.Completed?.fields?.signature;
  if (Array.isArray(signature)) {
    return Buffer.from(signature).toString("hex");
  }
  if (signature instanceof Uint8Array) {
    return Buffer.from(signature).toString("hex");
  }
  return typeof signature === "string" ? signature : "";
}

async function refreshObjectRef(objectId: string) {
  const client = new SuiJsonRpcClient({
    url: SUI_RPC_URL,
    network: "testnet",
  });
  const object = await client.getObject({ id: objectId });
  if (!object.data?.version || !object.data.digest) {
    throw new Error(`Could not refresh Sui object ref for ${objectId}`);
  }
  return {
    objectId,
    version: object.data.version,
    digest: object.data.digest,
  };
}

// --- Light-client bootstrap (added so the flow is self-sufficient on a fresh deploy) ---
async function ensureLightClientInitialized() {
  if (state.lightClient) {
    await assertLightClientMatchesRegtest();
    await ensurePoolLightClientBound();
    return state.lightClient;
  }
  const tipHeight = Number(bitcoinCli("getblockcount").trim());
  const anchorHash = bitcoinCli(`getblockhash ${tipHeight}`).trim();
  const anchorRawHeader = Uint8Array.from(Buffer.from(bitcoinCli(`getblockheader ${anchorHash} false`).trim(), "hex"));
  const anchor = JSON.parse(bitcoinCli(`getblock ${anchorHash} 1`));
  console.log(`Initializing Sui BTC light client anchored at regtest block ${tipHeight} (${anchorHash})...`);
  const tx = new Transaction();
  tx.moveCall({
    target: `${packageId}::btc_light_client::initialize`,
    arguments: [
      tx.pure.u8(3),
      tx.pure.vector("u8", Array.from(anchorRawHeader)),
      tx.pure.u64(BigInt(anchor.height)),
      tx.pure.u256(BigInt(`0x${anchor.chainwork}`)),
      tx.pure.u32(Number.parseInt(anchor.bits, 16)),
      tx.pure.u32(Number(anchor.time)),
    ],
  });
  const result = await executeBuiltTransaction(tx);
  if (result.effects?.status?.status !== "success") {
    throw new Error(`light-client init failed: ${JSON.stringify(result.effects?.status)}`);
  }
  const changes = result.objectChanges ?? [];
  state.lightClient = sharedRefFromChange(findCreatedObject(changes, "::btc_light_client::LightClient"));
  state.lightClientAdminCap = objectRefFromChange(findCreatedObject(changes, "::btc_light_client::LightClientAdminCap"));
  writeState(state);
  console.log(`light client = ${state.lightClient?.objectId}`);
  await ensurePoolLightClientBound();
  return state.lightClient!;
}

async function assertLightClientMatchesRegtest() {
  const c = new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" });
  const obj = await c.getObject({ id: state.lightClient!.objectId, options: { showContent: true } });
  const fields = (obj.data?.content as any)?.fields;
  const tipHeight = Number(fields?.tip_height ?? fields?.tipHeight ?? 0);
  const tipHashBytes = fields?.tip_hash ?? fields?.tipHash;
  if (!Number.isInteger(tipHeight) || !Array.isArray(tipHashBytes)) {
    throw new Error(`Could not read Sui BTC light-client tip for ${state.lightClient!.objectId}`);
  }
  const regtestHeight = Number(bitcoinCli("getblockcount").trim());
  if (tipHeight > regtestHeight) {
    throw new Error(
      `Sui light client tip height ${tipHeight} is ahead of regtest height ${regtestHeight}. ` +
      "Use matching state/regtest data or redeploy/reinitialize before running the flow.",
    );
  }
  const regtestHash = bitcoinCli(`getblockhash ${tipHeight}`).trim();
  const actual = toHex(Uint8Array.from(tipHashBytes));
  const expected = toHex(reverseHexToBytes(regtestHash));
  if (actual !== expected) {
    throw new Error(
      [
        "Sui light client does not match the running Bitcoin regtest chain.",
        `  lightClient=${state.lightClient!.objectId}`,
        `  height=${tipHeight}`,
        `  suiTip=${actual}`,
        `  regtestTip=${expected}`,
        "Start the matching regtest service, or clear/redeploy the Sui state before running the flow.",
      ].join("\n"),
    );
  }
}

async function ensurePoolLightClientBound() {
  const adminCap = requireState(state.adminCap, "adminCap");
  const c = new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" });
  const obj = await c.getObject({ id: pool.objectId, options: { showContent: true } });
  const fields = (obj.data?.content as any)?.fields ?? {};
  const tx = new Transaction();
  let changed = false;
  if (!fields.light_client_id) {
    console.log("Binding pool.light_client_id to the light client...");
    tx.moveCall({
      target: `${packageId}::pool::set_light_client_id`,
      arguments: [
        tx.object(adminCap.objectId),
        tx.sharedObjectRef({ objectId: pool.objectId, initialSharedVersion: pool.initialSharedVersion, mutable: true }),
        tx.pure.address(state.lightClient!.objectId),
      ],
    });
    changed = true;
  }
  if (!fields.btc_pool_script) {
    console.log("Binding pool.btc_pool_script to the regtest BTC pool address...");
    tx.moveCall({
      target: `${packageId}::pool::set_btc_pool_script`,
      arguments: [
        tx.object(adminCap.objectId),
        tx.sharedObjectRef({ objectId: pool.objectId, initialSharedVersion: pool.initialSharedVersion, mutable: true }),
        tx.pure.vector("u8", addressToScriptPubKey(getRegtestPoolBtcAddress())),
      ],
    });
    changed = true;
  }
  if (!changed) return;
  const result = await executeBuiltTransaction(tx);
  if (result.effects?.status?.status !== "success") {
    throw new Error(`pool BTC binding failed: ${JSON.stringify(result.effects?.status)}`);
  }
  const adminChange = (result.objectChanges ?? []).find((ch: any) => ch.objectId === adminCap.objectId && (ch.type === "mutated" || ch.type === "created"));
  state.adminCap = objectRefFromChange(adminChange) ?? state.adminCap;
  writeState(state);
}

function getRegtestPoolBtcAddress(): string {
  if (!regtestPoolBtcAddress) {
    regtestPoolBtcAddress = getNewAddress("bech32m");
    (state as any).regtestPoolBtcAddress = regtestPoolBtcAddress;
    writeState(state);
    console.log(`Using generated regtest BTC pool address: ${regtestPoolBtcAddress}`);
  }
  return regtestPoolBtcAddress;
}

async function lcTipHeight(): Promise<number> {
  const c = new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" });
  const obj = await c.getObject({ id: state.lightClient!.objectId, options: { showContent: true } });
  const fields = (obj.data?.content as any)?.fields;
  return Number(fields?.tip_height ?? fields?.tipHeight ?? 0);
}

async function submitHeadersThrough(height: number) {
  let tip = await lcTipHeight();
  if (tip >= height) return;
  for (let start = tip + 1; start <= height; start += 10) {
    const end = Math.min(height, start + 10 - 1);
    const parts: number[] = [];
    for (let h = start; h <= end; h += 1) {
      const hash = bitcoinCli(`getblockhash ${h}`).trim();
      parts.push(...Array.from(Buffer.from(bitcoinCli(`getblockheader ${hash} false`).trim(), "hex")));
    }
    console.log(`Submitting Sui BTC headers ${start}-${end} to light client...`);
    const tx = new Transaction();
    tx.moveCall({
      target: `${packageId}::btc_light_client::submit_headers`,
      arguments: [
        tx.sharedObjectRef({ objectId: state.lightClient!.objectId, initialSharedVersion: state.lightClient!.initialSharedVersion, mutable: true }),
        tx.pure.vector("u8", parts),
        tx.object.clock(),
      ],
    });
    const result = await executeBuiltTransaction(tx);
    if (result.effects?.status?.status !== "success") {
      throw new Error(`submit_headers ${start}-${end} failed: ${JSON.stringify(result.effects?.status)}`);
    }
  }
}

// ============================ Redeem → Ika BTC withdraw leg ============================

function beBytesToBigint(b: Uint8Array): bigint { let v = 0n; for (const x of b) v = (v << 8n) | BigInt(x); return v; }
function le64(v: bigint): Uint8Array { const o = new Uint8Array(8); for (let i = 0; i < 8; i++) { o[i] = Number(v & 0xffn); v >>= 8n; } return o; }
function fieldToBe(v: bigint): Uint8Array { const o = new Uint8Array(32); for (let i = 31; i >= 0; i--) { o[i] = Number(v & 0xffn); v >>= 8n; } return o; }
function cat(parts: Uint8Array[]): Uint8Array { const n = parts.reduce((s, p) => s + p.length, 0); const o = new Uint8Array(n); let off = 0; for (const p of parts) { o.set(p, off); off += p.length; } return o; }

// bound_params::redeem_hash → field value (BE(sha256(payload)) mod r). flag=REDEEM(2).
function redeemHashFieldValue(scripts: Uint8Array[], stealthData: Uint8Array[]): bigint {
  const scriptHash = sha256(cat(scripts));
  const stealthHash = sha256(cat(stealthData));
  const payload = cat([new Uint8Array([0, 0, 0, 0]), new Uint8Array([2]), scriptHash, le64(784n), stealthHash]);
  return beBytesToBigint(sha256(payload)) % BN254_FIELD_PRIME;
}

// Merkle path for an EXISTING leaf at `index` (uses all current leaves).
async function buildMerkleProofAtIndex(index: number) {
  const leaves = await fetchExistingLeaves();
  const zero = computeZeroHashes();
  let level: bigint[] = [...leaves];
  const siblings: bigint[] = [];
  let idx = index;
  for (let d = 0; d < TREE_DEPTH; d += 1) {
    const sibIdx = idx ^ 1;
    siblings.push(sibIdx < level.length ? level[sibIdx] : zero[d]);
    const next: bigint[] = [];
    for (let i = 0; i < level.length; i += 2) { const l = level[i]; const r = i + 1 < level.length ? level[i + 1] : zero[d]; next.push(poseidonHashSync([l, r])); }
    level = next.length ? next : [zero[d + 1]];
    idx >>= 1;
  }
  return { root: level[0], siblings, index };
}

async function runRedeemAndWithdraw(note: any, deposit: any, redeemFrontier: { nextIndex: number; frontier: bigint[] }) {
  const s = note.secrets;
  const redeemInputLeaf = redeemFrontier.nextIndex; // transfer inserted the output note here
  const noteValue = s.value as bigint;
  const redeemBtcSats = BigInt(process.env.UTXOPIA_SUI_REDEEM_BTC_SATS ?? "25000");
  const changeNoteSats = noteValue - redeemBtcSats;
  if (changeNoteSats <= 0n) throw new Error("note value must exceed redeem amount for a change note");

  const withdrawAddr = process.env.UTXOPIA_SUI_REGTEST_WITHDRAW_BTC_ADDRESS ?? getNewAddress("bech32m");
  const withdrawScript = addressToScriptPubKey(withdrawAddr);

  // --- redeem proof (joinsplit_1x2): input = transfer output note; outputs = [change note, public redeem] ---
  const merkle = buildRightmostPath(note.outputCommitment, redeemFrontier.frontier, redeemInputLeaf);
  const nullifier = poseidonHashSync([s.nullifyingKey, BigInt(redeemInputLeaf)]);
  const changeRandom = randomFieldElement();
  const changeNpk = poseidonHashSync([s.mpk, changeRandom]);
  const changeCommitment = poseidonHashSync([changeNpk, ZKBTC_TOKEN_ID, changeNoteSats]);
  const redeemCommitment = poseidonHashSync([0n, ZKBTC_TOKEN_ID, redeemBtcSats]); // public_redeem_commitment (npk=0)
  const stealth0 = fieldToBe(changeNpk); // any consistent 32 bytes; hashed into bound_params
  const boundParamsHash = redeemHashFieldValue([withdrawScript], [stealth0]);
  const msgHash = poseidonHashSync([merkle.root, boundParamsHash, nullifier, changeCommitment, redeemCommitment]);
  const sig = await eddsaPoseidonSign(s.seed, msgHash);

  const inputs = {
    merkleRoot: merkle.root.toString(),
    boundParamsHash: boundParamsHash.toString(),
    nullifiers: [nullifier.toString()],
    commitmentsOut: [changeCommitment.toString(), redeemCommitment.toString()],
    token: ZKBTC_TOKEN_ID.toString(),
    publicKey: [s.publicKey.x.toString(), s.publicKey.y.toString()],
    signature: sig.map((x: bigint) => x.toString()),
    nullifyingKey: s.nullifyingKey.toString(),
    randomIn: [s.outputRandom.toString()],
    valueIn: [noteValue.toString()],
    leavesIndices: [String(redeemInputLeaf)],
    pathElements: [merkle.siblings.map((x) => x.toString())],
    npkOut: [changeNpk.toString(), "0"],
    valueOut: [changeNoteSats.toString(), redeemBtcSats.toString()],
  };
  console.log(`Generating ${"joinsplit_1x2"} redeem proof (redeem ${redeemBtcSats} sats, change note ${changeNoteSats})...`);
  const artifacts = generateProof("joinsplit_1x2", inputs, { tmpPrefix: "regtest-flow" });
  verifyProof("joinsplit_1x2", artifacts.proofPath, artifacts.publicPath);
  const exported = exportSuiProof(artifacts.proofPath, artifacts.publicPath);
  const pub = hexToBytes(exported.publicInputs);
  const redeemVk = requireState(state.vk?.["joinsplit_1x2"], `${"joinsplit_1x2"} vk`);

  // On-chain redeem: n_inputs=1, n_outputs=2, n_public_outputs=1, n_tree_outputs=1.
  console.log("Submitting Sui redemption::redeem proof...");
  const redeemTx = await adapter.buildRedemptionTransaction({
    nInputs: 1, nOutputs: 2, nPublicOutputs: 1,
    vkHash: hexToBytes(redeemVk.vkHash),
    publicInputs: pub,
    proofPoints: hexToBytes(exported.proofPoints),
    nullifiers: [Uint8Array.from(pub.slice(64, 96)).reverse()],
    commitmentsOut: [Uint8Array.from(pub.slice(96, 128)).reverse(), Uint8Array.from(pub.slice(128, 160)).reverse()],
    btcScripts: [withdrawScript],
    amountsSats: [redeemBtcSats],
    maxFeesSats: [BigInt(process.env.UTXOPIA_SUI_REDEEM_MAX_FEE_SATS ?? "5000")],
    stealthData: [stealth0],
  });
  const redeemRes = await executeTransactionKind(redeemTx.bytes);
  assertSuiSuccess("redeem", redeemRes);
  const redemptionId = extractRedemptionId(redeemRes);
  console.log(`redeem OK: redemptionId=${redemptionId} digest=${redeemRes.digest}`);

  // ---- BTC settlement: mark_processing → approve_signing → Ika Taproot sign → broadcast → complete_redemption ----
  if (!ikaSigningConfig) throw new Error("set UTXOPIA_SUI_WITHDRAW_SIGNER_MODE=ika for the Ika BTC payout");
  const poolScript = addressToScriptPubKey(deposit.poolAddress);
  const depositValue = deposit.amountSats as bigint;
  const btcFee = BigInt(process.env.UTXOPIA_SUI_REDEEM_BTC_FEE_SATS ?? "1000");
  const poolChange = depositValue - redeemBtcSats - btcFee;
  if (poolChange < 0n) throw new Error("deposit UTXO too small for redeem + fee");

  const ins = [{ txidLE: reverseHexToBytes(deposit.depositTxid), vout: deposit.depositVout, sequence: 0xffffffff }];
  const outs = poolChange > 546n
    ? [{ value: redeemBtcSats, script: withdrawScript }, { value: poolChange, script: poolScript }]
    : [{ value: redeemBtcSats, script: withdrawScript }];

  await refreshCapAdapter();
  console.log("mark_processing (reserve pool UTXO)...");
  const mpTx = await adapter.buildMarkProcessingTransaction({
    redemptionId,
    selectedUtxos: [{ txid: ins[0].txidLE, vout: ins[0].vout }],
    estimatedMinerFeeSats: btcFee,
  });
  assertSuiSuccess("mark_processing", await executeTransactionKind(mpTx.bytes));

  const preimage = taprootKeyPathPreimage(2, ins, outs, 0, 0, [poolScript], [depositValue]);
  const sighash = sha256(preimage); // == BIP341 TapSighash

  await refreshCapAdapter();
  console.log("approve_signing (policy gate)...");
  const apTx = await adapter.buildIkaApprovalTransaction({
    redemptionId,
    sighash,
    dwalletCapId: ikaSigningConfig.dWalletCapObjectId,
    estimatedMinerFeeSats: btcFee,
  });
  assertSuiSuccess("approve_signing", await executeTransactionKind(apTx.bytes));

  console.log("Ika Taproot signing the BTC sighash preimage...");
  const taprootSig = await ikaTaprootSign(preimage);
  const ok = schnorrVerify(taprootSig, sighash, hexToBytes(state.ikaSui!.dWalletXOnlyPubkey!));
  console.log(`  Ika signature ${taprootSig.length}B, verifies against dWallet x-only key over TapSighash: ${ok}`);
  if (!ok) throw new Error("Ika signature does not verify against the TapSighash — aborting before broadcast");

  const signedTx = serializeTxWitness(2, ins, outs, 0, [[taprootSig]]);
  const noWit = serializeTxNoWitness(2, ins, outs, 0);
  const withdrawTxidDisplay = toHex(Uint8Array.from(doubleSha256(noWit)).reverse()).replace(/^0x/, "");
  console.log(`Broadcasting BTC payout ${withdrawTxidDisplay} ...`);
  const broadcastTxid = bitcoinCli(`sendrawtransaction ${Buffer.from(signedTx).toString("hex")}`).trim();
  mineBlocks(6);
  await waitForTxIndexed(broadcastTxid, ESPLORA_URL);

  await refreshCapAdapter();
  console.log("complete_redemption (SPV-verify payout)...");
  const wProof = await fetchMerkleProof(broadcastTxid, ESPLORA_URL);
  await submitHeadersThrough(wProof.block_height);
  const wBlockHash = btc(`getblockhash ${wProof.block_height}`);
  const completeTx = await adapter.buildCompleteRedemptionTransaction({
    redemptionId,
    btcTxid: reverseHexToBytes(broadcastTxid),
    blockHash: reverseHexToBytes(wBlockHash),
    txIndex: wProof.pos,
    merkleSiblings: wProof.merkle.map(reverseHexToBytes),
    pathBits: BigInt(wProof.pos),
    rawTx: noWit,
  });
  const completeRes = await executeTransactionKind(completeTx.bytes);
  assertSuiSuccess("complete_redemption", completeRes);

  (state as any).lastSuiRedeem = {
    redemptionId: String(redemptionId), redeemDigest: redeemRes.digest,
    withdrawAddr, redeemBtcSats: redeemBtcSats.toString(),
    btcPayoutTxid: broadcastTxid, completeDigest: completeRes.digest,
  };
  writeState(state);
  console.log("FULL CYCLE COMPLETE");
  console.log(JSON.stringify({ redeem: (state as any).lastSuiRedeem }, null, 2));
}

function schnorrVerify(sig: Uint8Array, msg: Uint8Array, xonly: Uint8Array): boolean {
  try { return schnorr.verify(sig, msg, xonly); } catch { return false; }
}

function extractRedemptionId(result: any): bigint {
  for (const e of result.events ?? []) {
    const pj = e.parsedJson ?? {};
    if (pj.redemption_id !== undefined) return BigInt(pj.redemption_id);
    if (pj.redemptionId !== undefined) return BigInt(pj.redemptionId);
  }
  throw new Error("could not find redemption_id in redeem events");
}

function addressToScriptPubKey(addr: string): Uint8Array {
  const info = JSON.parse(bitcoinCli(`getaddressinfo ${addr}`));
  return hexToBytes(info.scriptPubKey);
}

// ---- BTC tx serialization + BIP341 key-path sighash preimage (for Ika Taproot signing) ----
function u32le(n: number): Uint8Array { const o = new Uint8Array(4); new DataView(o.buffer).setUint32(0, n, true); return o; }
function u64le(v: bigint): Uint8Array { const o = new Uint8Array(8); new DataView(o.buffer).setBigUint64(0, v, true); return o; }
function varint(n: number): Uint8Array {
  if (n < 0xfd) return new Uint8Array([n]);
  if (n <= 0xffff) return cat([new Uint8Array([0xfd]), (() => { const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, n, true); return b; })()]);
  return cat([new Uint8Array([0xfe]), u32le(n)]);
}
function doubleSha256(b: Uint8Array): Uint8Array { return sha256(sha256(b)); }

interface BtcIn { txidLE: Uint8Array; vout: number; sequence: number; }
interface BtcOut { value: bigint; script: Uint8Array; }

function serializeTxNoWitness(version: number, ins: BtcIn[], outs: BtcOut[], locktime: number): Uint8Array {
  const parts: Uint8Array[] = [u32le(version), varint(ins.length)];
  for (const i of ins) parts.push(i.txidLE, u32le(i.vout), varint(0), u32le(i.sequence));
  parts.push(varint(outs.length));
  for (const o of outs) parts.push(u64le(o.value), varint(o.script.length), o.script);
  parts.push(u32le(locktime));
  return cat(parts);
}
function serializeTxWitness(version: number, ins: BtcIn[], outs: BtcOut[], locktime: number, witnesses: Uint8Array[][]): Uint8Array {
  const parts: Uint8Array[] = [u32le(version), new Uint8Array([0x00, 0x01]), varint(ins.length)];
  for (const i of ins) parts.push(i.txidLE, u32le(i.vout), varint(0), u32le(i.sequence));
  parts.push(varint(outs.length));
  for (const o of outs) parts.push(u64le(o.value), varint(o.script.length), o.script);
  for (const w of witnesses) { parts.push(varint(w.length)); for (const item of w) parts.push(varint(item.length), item); }
  parts.push(u32le(locktime));
  return cat(parts);
}

// BIP341 key-path sighash preimage: SHA256(preimage) == TapSighash. SIGHASH_DEFAULT, single input.
function taprootKeyPathPreimage(version: number, ins: BtcIn[], outs: BtcOut[], locktime: number, inIndex: number, prevScripts: Uint8Array[], prevValues: bigint[]): Uint8Array {
  const hashPrevouts = sha256(cat(ins.map((i) => cat([i.txidLE, u32le(i.vout)]))));
  const hashAmounts = sha256(cat(prevValues.map(u64le)));
  const hashScriptPubKeys = sha256(cat(prevScripts.map((s) => cat([varint(s.length), s]))));
  const hashSequences = sha256(cat(ins.map((i) => u32le(i.sequence))));
  const hashOutputs = sha256(cat(outs.map((o) => cat([u64le(o.value), varint(o.script.length), o.script]))));
  const sigMsg = cat([
    new Uint8Array([0x00]),        // hash_type = SIGHASH_DEFAULT
    u32le(version), u32le(locktime),
    hashPrevouts, hashAmounts, hashScriptPubKeys, hashSequences, hashOutputs,
    new Uint8Array([0x00]),        // spend_type (key-path, no annex)
    u32le(inIndex),
  ]);
  const tag = sha256(new TextEncoder().encode("TapSighash"));
  return cat([tag, tag, new Uint8Array([0x00]), sigMsg]);
}

async function ikaTaprootSign(preimage: Uint8Array): Promise<Uint8Array> {
  const cfg = ikaSigningConfig!;
  const ikaAdapter = new UTXOpiaSuiIkaAdapter({
    rpcUrl: SUI_RPC_URL, network: cfg.network,
    dWalletId: cfg.dWalletId, dWalletCapObjectId: cfg.dWalletCapObjectId,
    networkEncryptionKeyId: cfg.networkEncryptionKeyId,
    ikaCoinObjectId: cfg.ikaCoinObjectId, suiCoinObjectId: cfg.suiCoinObjectId,
    encryptedUserSecretKeyShareId: cfg.encryptedUserSecretKeyShareId,
    userShareEncryptionKeys: await loadOrCreateIkaUserShareKeys(),
    suiPaymentReturnAddress: state.relayer?.address,
  });
  const ikaClient = ikaAdapter.createClient();
  await ikaClient.initialize();
  const waitOptions = { timeout: 180000, interval: 1500, maxInterval: 6000 };
  const presignTx = await ikaAdapter.buildRequestGlobalTaprootPresignTransaction();
  const presignRes = await executeTransactionKind(presignTx.bytes);
  assertSuiSuccess("ika presign", presignRes);
  const presignId = findCreatedObjectId(presignRes, "coordinator_inner::PresignSession");
  if (!presignId) throw new Error("no PresignSession");
  await ikaClient.getPresignInParticularState(presignId, "Completed", waitOptions);
  const signTx = await ikaAdapter.buildTaprootSignWithPublicSharesTransaction({ presignId, message: preimage });
  const signRes = await executeTransactionKind(signTx.bytes);
  assertSuiSuccess("ika sign", signRes);
  const signId = findCreatedObjectId(signRes, "coordinator_inner::SignSession");
  if (!signId) throw new Error("no SignSession");
  const sign = await ikaClient.getSignInParticularState(signId, Curve.SECP256K1, SignatureAlgorithm.Taproot, "Completed", waitOptions);
  const hex = extractCompletedSignatureHex(sign);
  const sig = hexToBytes(hex.replace(/^0x/, ""));
  return sig.length === 64 ? sig : sig.subarray(sig.length - 64);
}
