#!/usr/bin/env bun
/**
 * Create a NEW permissioned pool bound to a given auditor address ("store a new
 * address as a new auditor with its own pool"), with its OWN full companion set.
 *
 * Unlike scripts/init.ts (which initializes the single canonical pool and writes
 * the top-level pool/commitmentTree/... fields), this script appends a fully
 * self-contained pool to `state.pools[]`. Each permissioned pool gets:
 *   - its own AdminCap (to the sender) and AuditorCap (to `auditor`)
 *   - its own commitment tree, nullifier registry, btc deposit registry, utxo set,
 *     verifying-key registry, and redemption queue
 *   - each companion pinned to THIS pool via the new AdminCap's set_*_id binders
 *
 * The on-chain `pool::initialize_permissioned(tree_depth, auditor, ctx)` mints the
 * AuditorCap to `auditor`; deposits then require the auditor co-signature (fail-closed).
 *
 * Usage:
 *   bun run scripts/init-permissioned.ts <auditorAddress> [--viewing-pubkey <hex>] [--tree-depth <n>]
 *
 *   <auditorAddress>          required, 0x-prefixed Sui address that receives the AuditorCap
 *   --viewing-pubkey <hex>    optional, hex-encoded auditor viewing pubkey (set via AuditorCap)
 *   --tree-depth <n>          optional, commitment tree depth (default 16)
 *
 * Web config: this script does NOT auto-edit the web networks.json. See the printed
 * summary for the exact `sui` fields a permissioned-pool web entry should copy
 * (the fields the web's usePoolPermissioned + NetworkConfig read).
 */
import { spawnSync } from "node:child_process";
import {
  ROOT,
  findCreatedObject,
  findCreatedAuditorCap,
  parseJsonFromStdout,
  readState,
  requireState,
  stateFile,
  writeState,
} from "./shared";

const gasBudget = process.env.UTXOPIA_SUI_GAS_BUDGET ?? "100000000";

// ---- args -----------------------------------------------------------------
const argv = process.argv.slice(2);
let auditorAddress: string | undefined;
let viewingPubkey: string | undefined;
let treeDepth = 16;

for (let i = 0; i < argv.length; i++) {
  const arg = argv[i];
  if (arg === "--viewing-pubkey") {
    viewingPubkey = argv[++i];
  } else if (arg === "--tree-depth") {
    treeDepth = Number(argv[++i]);
  } else if (arg.startsWith("--")) {
    console.error(`Unknown flag: ${arg}`);
    process.exit(1);
  } else if (!auditorAddress) {
    auditorAddress = arg;
  } else {
    console.error(`Unexpected positional argument: ${arg}`);
    process.exit(1);
  }
}

if (!auditorAddress || !/^0x[0-9a-fA-F]+$/.test(auditorAddress)) {
  console.error(
    "Usage: bun run scripts/init-permissioned.ts <auditorAddress 0x...> [--viewing-pubkey <hex>] [--tree-depth <n>]",
  );
  process.exit(1);
}
if (!Number.isInteger(treeDepth) || treeDepth <= 0) {
  console.error(`--tree-depth must be a positive integer (got ${treeDepth})`);
  process.exit(1);
}
const normalizedPubkey = viewingPubkey?.startsWith("0x")
  ? viewingPubkey.slice(2)
  : viewingPubkey;
if (normalizedPubkey !== undefined && !/^[0-9a-fA-F]*$/.test(normalizedPubkey)) {
  console.error("--viewing-pubkey must be hex");
  process.exit(1);
}

// After validation above, auditorAddress is a concrete string (the `!auditorAddress`
// guard exits; without @types/node, tsc can't see process.exit as `never`, hence `!`).
const auditor: string = auditorAddress!;

const state = readState();
const packageId = requireState(state.packageId, "packageId");

// ---- create the permissioned pool -----------------------------------------
// initialize_permissioned(tree_depth, auditor): shares Pool (permissioned=true),
// AdminCap -> sender, AuditorCap -> auditor.
const poolCh = call("pool", "initialize_permissioned", [String(treeDepth), auditor]);
const poolObj = findCreatedObject(poolCh, "::pool::Pool");
const adminCapObj = findCreatedObject(poolCh, "::pool::AdminCap");
const auditorCapObj = findCreatedAuditorCap(poolCh);
if (!poolObj || !adminCapObj || !auditorCapObj) {
  console.error("Failed to capture Pool / AdminCap / AuditorCap from initialize_permissioned");
  process.exit(1);
}
const poolId: string = poolObj.objectId;
const adminCapId: string = adminCapObj.objectId;
const auditorCapId: string = auditorCapObj.objectId;

// ---- create this pool's OWN full companion set -----------------------------
const treeCh = call("commitment_tree", "initialize", []);
const commitmentTreeId = required(findCreatedObject(treeCh, "::commitment_tree::CommitmentTree"), "CommitmentTree");

const regCh = call("btc_deposit", "initialize_registry", []);
const btcDepositRegistryId = required(findCreatedObject(regCh, "::btc_deposit::BtcDepositRegistry"), "BtcDepositRegistry");

const utxoCh = call("btc_deposit", "initialize_utxo_set", []);
const utxoSetId = required(findCreatedObject(utxoCh, "::btc_deposit::UtxoSet"), "UtxoSet");

const nullCh = call("nullifier", "initialize_registry", []);
const nullifierRegistryId = required(findCreatedObject(nullCh, "::nullifier::NullifierRegistry"), "NullifierRegistry");

const redCh = call("redemption", "initialize_queue", []);
const redemptionQueueId = required(findCreatedObject(redCh, "::redemption::RedemptionQueue"), "RedemptionQueue");

const vkCh = call("verifier", "initialize_registry", []);
const vkRegistryId = required(findCreatedObject(vkCh, "::verifier::VerifyingKeyRegistry"), "VerifyingKeyRegistry");

// ---- pin each companion to THIS pool via its own AdminCap ------------------
// Mirror init.ts: AdminCap-gated, set-once binders so transact/complete_deposit
// reject any substitute companion for this permissioned pool.
call("pool", "set_commitment_tree_id", [adminCapId, poolId, commitmentTreeId]);
call("pool", "set_nullifier_registry_id", [adminCapId, poolId, nullifierRegistryId]);
call("pool", "set_btc_deposit_registry_id", [adminCapId, poolId, btcDepositRegistryId]);
call("pool", "set_utxo_set_id", [adminCapId, poolId, utxoSetId]);
call("pool", "set_vk_registry_id", [adminCapId, poolId, vkRegistryId]);

// ---- optionally set the auditor viewing pubkey (AuditorCap-gated) ----------
if (normalizedPubkey) {
  call("pool", "set_auditor_viewing_pubkey", [auditorCapId, poolId, `0x${normalizedPubkey}`]);
}

// ---- record into state.pools[] ---------------------------------------------
const entry = {
  poolId,
  adminCapId,
  auditorCapId,
  auditor,
  ...(normalizedPubkey ? { auditorViewingPubkey: normalizedPubkey } : {}),
  commitmentTreeId,
  nullifierRegistryId,
  btcDepositRegistryId,
  utxoSetId,
  vkRegistryId,
  redemptionQueueId,
  treeDepth,
  permissioned: true as const,
  createdAt: new Date().toISOString(),
};
const pools = [...(state.pools ?? []), entry];
state.pools = pools;
writeState(state);

// ---- summary ----------------------------------------------------------------
console.log(`Wrote ${stateFile()} (state.pools[${pools.length - 1}])`);
console.log(JSON.stringify(entry, null, 2));
console.log(`\nPermissioned pool created:`);
console.log(`  pool id     : ${poolId}`);
console.log(`  auditor     : ${auditor}`);
console.log(`  auditorCap  : ${auditorCapId}  (transferred to auditor)`);
console.log(`  adminCap    : ${adminCapId}`);
console.log(
  `\nWeb config — to surface this pool in web networks.json (usePoolPermissioned + NetworkConfig),\n` +
    `add a permissioned entry whose \`sui\` block carries:\n` +
    JSON.stringify(
      {
        permissioned: true,
        auditorCapId,
        ...(normalizedPubkey ? { auditorViewingPubkey: normalizedPubkey } : {}),
        pool: { objectId: poolId },
        commitmentTree: { objectId: commitmentTreeId },
        nullifierRegistry: { objectId: nullifierRegistryId },
        btcDepositRegistry: { objectId: btcDepositRegistryId },
        utxoSet: { objectId: utxoSetId },
        verifyingKeyRegistry: { objectId: vkRegistryId },
        redemptionQueue: { objectId: redemptionQueueId },
      },
      null,
      2,
    ),
);

// ---- helpers ----------------------------------------------------------------
function required(change: any, label: string): string {
  if (!change?.objectId) {
    console.error(`Failed to capture ${label} from initialize call`);
    process.exit(1);
  }
  return change.objectId;
}

function call(module: string, fn: string, args: string[]): any[] {
  const result = spawnSync("sui", [
    "client",
    "call",
    "--package",
    packageId,
    "--module",
    module,
    "--function",
    fn,
    "--gas-budget",
    gasBudget,
    "--json",
    ...(args.length ? ["--args", ...args] : []),
  ], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.status !== 0) {
    console.error(result.stderr || result.stdout);
    process.exit(result.status ?? 1);
  }

  const output = parseJsonFromStdout(result.stdout) as any;
  return output.objectChanges ?? [];
}
