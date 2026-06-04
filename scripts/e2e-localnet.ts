/**
 * Standalone localnet E2E for the Move contracts (no @utxopia/sdk dependency).
 * Drives the full trustless flow on a live validator: init -> submit_headers ->
 * (verify_tx_inclusion + complete_deposit in one PTB) -> double-claim reject ->
 * request_redemption -> approve_signing -> consume_approval -> fee-over-cap reject.
 *
 * Run:
 *   RUST_LOG=off sui start --with-faucet --force-regenesis &
 *   sui client switch --env local && sui client faucet
 *   (cd contracts && sui client test-publish --build-env local --json > /tmp/pub.json)
 *   SUI_PKG=$(jq -r '.objectChanges[]|select(.type=="published").packageId' /tmp/pub.json) \
 *     bun run scripts/e2e-localnet.ts
 */
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { bcs } from "@mysten/sui/bcs";
import { requestSuiFromFaucetV2 } from "@mysten/sui/faucet";
import { createHash } from "node:crypto";

const RPC = process.env.SUI_RPC ?? "http://127.0.0.1:9000";
const FAUCET = process.env.SUI_FAUCET ?? "http://127.0.0.1:9123";
const PKG = process.env.SUI_PKG ?? process.argv[2];
if (!PKG) throw new Error("set SUI_PKG=<packageId> (from `sui client test-publish`)");
const REGTEST_BITS = 0x207fffff;

// ---- byte builders (mirror the Move tests) ----
const le = (n: number | bigint, bytes: number) => {
  const a: number[] = []; let v = BigInt(n);
  for (let i = 0; i < bytes; i++) { a.push(Number(v & 0xffn)); v >>= 8n; }
  return a;
};
const fill = (n: number, b: number) => Array(n).fill(b);
const dsha = (arr: number[]) =>
  Array.from(createHash("sha256").update(createHash("sha256").update(Buffer.from(arr)).digest()).digest());
const makeHeader = (prev: number[], merkle: number[], ts: number, bits: number, nonce: number) =>
  [...le(1, 4), ...prev, ...merkle, ...le(ts, 4), ...le(bits, 4), ...le(nonce, 4)];
const p2tr = (f: number) => [0x51, 0x20, ...fill(32, f)];
const opret = (eph: number, npk: number) => [0x6a, 0x40, ...fill(32, eph), ...fill(32, npk)];
const buildDepositTx = (v0: number, s0: number[], s1: number[]) => [
  ...le(1, 4), 0x01, ...fill(32, 0x11), ...le(7, 4), 0x00, ...le(0xffffffff, 4),
  0x02, ...le(v0, 8), s0.length, ...s0, ...le(0, 8), s1.length, ...s1, ...le(0, 4),
];

const vecU8 = (tx: Transaction, arr: number[]) => tx.pure(bcs.vector(bcs.u8()).serialize(arr).toBytes());
const vecVecU8 = (tx: Transaction, arr: number[][]) =>
  tx.pure(bcs.vector(bcs.vector(bcs.u8())).serialize(arr).toBytes());

const client = new SuiJsonRpcClient({ url: RPC });

async function main() {
  const kp = new Ed25519Keypair();
  const addr = kp.getPublicKey().toSuiAddress();
  console.log("E2E sender:", addr, "\npackage:", PKG);
  await requestSuiFromFaucetV2({ host: FAUCET, recipient: addr });
  // wait for gas
  for (let i = 0; i < 30; i++) {
    const c = await client.getCoins({ owner: addr });
    if (c.data.length) break;
    await new Promise((r) => setTimeout(r, 1000));
  }

  const exec = async (tx: Transaction, label: string) => {
    tx.setGasBudget(1_000_000_000);
    const res = await client.signAndExecuteTransaction({
      signer: kp, transaction: tx,
      options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });
    const status = res.effects?.status?.status;
    console.log(`\n[${label}] ${status} (digest ${res.digest})`);
    if (status !== "success") { console.error(JSON.stringify(res.effects?.status, null, 2)); throw new Error(`${label} failed`); }
    await client.waitForTransaction({ digest: res.digest });
    return res;
  };

  // genesis + child block + deposit tx
  const genesis = makeHeader(fill(32, 0), fill(32, 9), 1000, REGTEST_BITS, 0);
  const genesisHash = dsha(genesis);
  const sweepTx = buildDepositTx(50_000, p2tr(0x22), opret(0x02, 0x01));
  const sweepTxid = dsha(sweepTx);
  const block = makeHeader(genesisHash, sweepTxid, 1001, REGTEST_BITS, 1);
  const blockHash = dsha(block);

  // ---- Tx1: initialize all shared objects ----
  const t1 = new Transaction();
  t1.moveCall({ target: `${PKG}::pool::initialize`, arguments: [t1.pure.u64(16)] });
  t1.moveCall({ target: `${PKG}::commitment_tree::initialize`, arguments: [] });
  t1.moveCall({ target: `${PKG}::btc_deposit::initialize_registry`, arguments: [] });
  t1.moveCall({ target: `${PKG}::btc_deposit::initialize_utxo_set`, arguments: [] });
  t1.moveCall({ target: `${PKG}::redemption::initialize_queue`, arguments: [] });
  t1.moveCall({
    target: `${PKG}::btc_light_client::initialize`,
    arguments: [
      t1.pure.u8(2), vecU8(t1, genesis), t1.pure.u64(100), t1.pure.u256(1000),
      t1.pure.u32(REGTEST_BITS), t1.pure.u32(1000),
    ],
  });
  const r1 = await exec(t1, "initialize");

  const find = (suffix: string) =>
    (r1.objectChanges as any[]).find((c) => c.type === "created" && c.objectType?.endsWith(suffix))?.objectId as string;
  const pool = find("::pool::Pool");
  const tree = find("::commitment_tree::CommitmentTree");
  const registry = find("::btc_deposit::BtcDepositRegistry");
  const utxoSet = find("::btc_deposit::UtxoSet");
  const light = find("::btc_light_client::LightClient");
  const queue = find("::redemption::RedemptionQueue");
  const redCap = find("::redemption::RedemptionCap");
  const adminCap = find("::pool::AdminCap");
  console.log({ pool, tree, registry, utxoSet, light, queue, redCap });

  // ---- Tx1b: pin the deposit-path companion objects to the pool (AdminCap-gated) ----
  // This harness exercises complete_deposit + redemption only, so it pins just the
  // tree, BTC deposit registry, and UTXO set. transact additionally requires pinned
  // NullifierRegistry + VerifyingKeyRegistry (this script does not create those);
  // scripts/init.ts pins the full set of five.
  const tb = new Transaction();
  tb.moveCall({ target: `${PKG}::pool::set_commitment_tree_id`, arguments: [tb.object(adminCap), tb.object(pool), tb.pure.id(tree)] });
  tb.moveCall({ target: `${PKG}::pool::set_btc_deposit_registry_id`, arguments: [tb.object(adminCap), tb.object(pool), tb.pure.id(registry)] });
  tb.moveCall({ target: `${PKG}::pool::set_utxo_set_id`, arguments: [tb.object(adminCap), tb.object(pool), tb.pure.id(utxoSet)] });
  await exec(tb, "bind canonical objects");

  const execExpectAbort = async (tx: Transaction, label: string, code: number) => {
    tx.setGasBudget(1_000_000_000);
    const res = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
    const st = res.effects?.status;
    if (st?.status !== "failure") throw new Error(`${label}: expected failure, got ${st?.status}`);
    const err = st?.error ?? "";
    if (!err.includes(`, ${code})`)) throw new Error(`${label}: expected abort ${code}, got: ${err}`);
    console.log(`[${label}] correctly aborted with code ${code}`);
    await client.waitForTransaction({ digest: res.digest });
  };

  // ---- Tx2: submit the block header ----
  const t2 = new Transaction();
  t2.moveCall({
    target: `${PKG}::btc_light_client::submit_headers`,
    arguments: [t2.object(light), vecU8(t2, block), t2.object.clock()],
  });
  await exec(t2, "submit_headers");

  // ---- Tx3: verify_tx_inclusion + complete_deposit (hot potato, same PTB) ----
  const t3 = new Transaction();
  const inclusion = t3.moveCall({
    target: `${PKG}::btc_light_client::verify_tx_inclusion`,
    arguments: [
      t3.object(light), vecU8(t3, blockHash), vecU8(t3, sweepTxid),
      t3.pure.u32(0), vecVecU8(t3, []), t3.pure.u64(0n),
    ],
  });
  t3.moveCall({
    target: `${PKG}::btc_deposit::complete_deposit`,
    arguments: [
      t3.object(pool), t3.object(registry), t3.object(utxoSet), t3.object(tree),
      inclusion, vecU8(t3, sweepTx), vecU8(t3, []), t3.pure.bool(true), vecU8(t3, []),
    ],
  });
  const r3 = await exec(t3, "verify_tx_inclusion + complete_deposit");

  const dep = (r3.events ?? []).find((e) => e.type.endsWith("::events::BtcDepositVerified"));
  console.log("\nBtcDepositVerified event:", JSON.stringify(dep?.parsedJson, null, 2));

  // read back the tree
  const treeObj = await client.getObject({ id: tree, options: { showContent: true } });
  const fields = (treeObj.data?.content as any)?.fields;
  console.log("tree.next_index:", fields?.next_index, " current_root set:", fields?.current_root ? "yes" : "no");

  const amount = (dep?.parsedJson as any)?.amount_sats;
  if (amount !== "50000" || fields?.next_index !== "1") {
    throw new Error(`E2E assertion failed: amount=${amount} next_index=${fields?.next_index}`);
  }
  console.log("✓ deposit credited (amount 50000, leaf 0)");

  // ---- Tx4: double-claim the same outpoint -> must abort 15 ----
  const t4 = new Transaction();
  const inc4 = t4.moveCall({
    target: `${PKG}::btc_light_client::verify_tx_inclusion`,
    arguments: [t4.object(light), vecU8(t4, blockHash), vecU8(t4, sweepTxid), t4.pure.u32(0), vecVecU8(t4, []), t4.pure.u64(0n)],
  });
  t4.moveCall({
    target: `${PKG}::btc_deposit::complete_deposit`,
    arguments: [t4.object(pool), t4.object(registry), t4.object(utxoSet), t4.object(tree), inc4, vecU8(t4, sweepTx), vecU8(t4, []), t4.pure.bool(true), vecU8(t4, [])],
  });
  await execExpectAbort(t4, "double-claim", 15);

  // ---- Redemption + policy flow ----
  const btcScript = p2tr(0x33); // raw destination scriptPubKey
  const sighash = fill(32, 0x7a);

  const t5 = new Transaction();
  t5.moveCall({
    target: `${PKG}::redemption::request_redemption`,
    arguments: [t5.object(redCap), t5.object(pool), t5.object(queue), vecU8(t5, btcScript), t5.pure.u64(30_000n), t5.pure.u64(1_000n)],
  });
  await exec(t5, "request_redemption");

  const t6 = new Transaction();
  t6.moveCall({
    target: `${PKG}::ika_policy::approve_signing`,
    arguments: [t6.object(redCap), t6.object(pool), t6.object(queue), t6.pure.address("0xdcab"), t6.pure.u64(0n), t6.pure.u64(800n), vecU8(t6, sighash)],
  });
  const r6 = await exec(t6, "approve_signing");
  const approval = (r6.objectChanges as any[]).find((c) => c.type === "created" && c.objectType?.endsWith("::ika_policy::SigningApproval"))?.objectId as string;
  console.log("  SigningApproval:", approval);

  const t7 = new Transaction();
  t7.moveCall({
    target: `${PKG}::ika_policy::consume_approval`,
    arguments: [t7.object(redCap), t7.object(pool), t7.object(queue), t7.object(approval)],
  });
  await exec(t7, "consume_approval");

  // policy rejection: fee over the 50k cap -> abort 7
  const t8 = new Transaction();
  t8.moveCall({
    target: `${PKG}::redemption::request_redemption`,
    arguments: [t8.object(redCap), t8.object(pool), t8.object(queue), vecU8(t8, btcScript), t8.pure.u64(20_000n), t8.pure.u64(100_000n)],
  });
  await exec(t8, "request_redemption #2");
  const t9 = new Transaction();
  t9.moveCall({
    target: `${PKG}::ika_policy::approve_signing`,
    arguments: [t9.object(redCap), t9.object(pool), t9.object(queue), t9.pure.address("0xdcab"), t9.pure.u64(1n), t9.pure.u64(60_000n), vecU8(t9, sighash)],
  });
  await execExpectAbort(t9, "fee-over-cap", 7);

  console.log("\n✅ E2E PASS (live validator): deposit credited; double-claim rejected (15); redemption approve+consume; fee-over-cap rejected (7).");
}

main().catch((e) => { console.error("E2E ERROR:", e); process.exit(1); });
