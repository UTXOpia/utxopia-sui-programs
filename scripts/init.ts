#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import {
  ROOT,
  findCreatedObject,
  parseJsonFromStdout,
  readState,
  requireState,
  sharedRefFromChange,
  objectRefFromChange,
  stateFile,
  writeState,
} from "./shared";

const gasBudget = process.env.UTXOPIA_SUI_GAS_BUDGET ?? "100000000";
const state = readState();
const packageId = requireState(state.packageId, "packageId");

// Pool (no initial_root — the commitment_tree is now the single source of truth).
const poolCh = call("pool", "initialize", ["16"]);
state.pool = sharedRefFromChange(findCreatedObject(poolCh, "::pool::Pool"));
state.adminCap = objectRefFromChange(findCreatedObject(poolCh, "::pool::AdminCap"));

// Real Poseidon commitment tree (replaces the old SHA256-chain merkle).
const treeCh = call("commitment_tree", "initialize", []);
state.commitmentTree = sharedRefFromChange(findCreatedObject(treeCh, "::commitment_tree::CommitmentTree"));

// Deposit dedup registry + pool UTXO set (Table-backed).
const regCh = call("btc_deposit", "initialize_registry", []);
state.btcDepositRegistry = sharedRefFromChange(findCreatedObject(regCh, "::btc_deposit::BtcDepositRegistry"));
const utxoCh = call("btc_deposit", "initialize_utxo_set", []);
state.utxoSet = sharedRefFromChange(findCreatedObject(utxoCh, "::btc_deposit::UtxoSet"));

const nullCh = call("nullifier", "initialize_registry", []);
state.nullifierRegistry = sharedRefFromChange(findCreatedObject(nullCh, "::nullifier::NullifierRegistry"));

const redCh = call("redemption", "initialize_queue", []);
state.redemptionQueue = sharedRefFromChange(findCreatedObject(redCh, "::redemption::RedemptionQueue"));
state.redemptionCap = objectRefFromChange(findCreatedObject(redCh, "::redemption::RedemptionCap"));

const vkCh = call("verifier", "initialize_registry", []);
state.verifyingKeyRegistry = sharedRefFromChange(findCreatedObject(vkCh, "::verifier::VerifyingKeyRegistry"));

// Pin all five canonical companion objects to the pool (AdminCap-gated, set once):
// commitment tree, nullifier registry, BTC deposit registry, UTXO set, and
// verifying-key registry — so transact/complete_deposit reject any substitute.
callWithAdminCap("pool", "set_commitment_tree_id", [state.adminCap!.objectId, state.pool!.objectId, state.commitmentTree!.objectId]);
callWithAdminCap("pool", "set_nullifier_registry_id", [state.adminCap!.objectId, state.pool!.objectId, state.nullifierRegistry!.objectId]);
callWithAdminCap("pool", "set_btc_deposit_registry_id", [state.adminCap!.objectId, state.pool!.objectId, state.btcDepositRegistry!.objectId]);
callWithAdminCap("pool", "set_utxo_set_id", [state.adminCap!.objectId, state.pool!.objectId, state.utxoSet!.objectId]);
callWithAdminCap("pool", "set_vk_registry_id", [state.adminCap!.objectId, state.pool!.objectId, state.verifyingKeyRegistry!.objectId]);

// NOTE: btc_light_client::initialize is a separate, network-specific bootstrap (it anchors
// a trusted checkpoint header + chainwork) driven by the header relayer — analogous to the
// standalone btc-light-client program on Solana. See scripts/e2e-localnet.ts for the full
// flow including light-client init + a deposit.

writeState(state);
console.log(`Wrote ${stateFile()}`);
console.log(JSON.stringify({
  pool: state.pool,
  commitmentTree: state.commitmentTree,
  btcDepositRegistry: state.btcDepositRegistry,
  utxoSet: state.utxoSet,
  nullifierRegistry: state.nullifierRegistry,
  redemptionQueue: state.redemptionQueue,
  redemptionCap: state.redemptionCap,
  verifyingKeyRegistry: state.verifyingKeyRegistry,
}, null, 2));

function callWithAdminCap(module: string, fn: string, args: string[]) {
  const changes = call(module, fn, args);
  const adminChange = changes.find((change: any) =>
    change.objectId === state.adminCap?.objectId && (change.type === "mutated" || change.type === "created")
  );
  state.adminCap = objectRefFromChange(adminChange) ?? state.adminCap;
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
