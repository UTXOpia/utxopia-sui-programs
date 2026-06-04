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

call("pool", "initialize", ["16", `0x${"00".repeat(32)}`]);
call("btc_deposit", "initialize_registry", []);
call("nullifier", "initialize_registry", []);
call("redemption", "initialize_queue", []);
call("verifier", "initialize_registry", []);

writeState(state);
console.log(`Wrote ${stateFile()}`);
console.log(JSON.stringify({
  pool: state.pool,
  btcDepositRegistry: state.btcDepositRegistry,
  nullifierRegistry: state.nullifierRegistry,
  redemptionQueue: state.redemptionQueue,
  redemptionCap: state.redemptionCap,
  verifyingKeyRegistry: state.verifyingKeyRegistry,
}, null, 2));

function call(module: string, fn: string, args: string[]) {
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
  const changes = output.objectChanges ?? [];

  if (module === "pool") {
    state.pool = sharedRefFromChange(findCreatedObject(changes, "::pool::Pool"));
    state.adminCap = objectRefFromChange(findCreatedObject(changes, "::pool::AdminCap"));
  } else if (module === "btc_deposit") {
    state.btcDepositRegistry = sharedRefFromChange(findCreatedObject(changes, "::btc_deposit::BtcDepositRegistry"));
  } else if (module === "nullifier") {
    state.nullifierRegistry = sharedRefFromChange(findCreatedObject(changes, "::nullifier::NullifierRegistry"));
  } else if (module === "redemption") {
    state.redemptionQueue = sharedRefFromChange(findCreatedObject(changes, "::redemption::RedemptionQueue"));
    state.redemptionCap = objectRefFromChange(findCreatedObject(changes, "::redemption::RedemptionCap"));
  } else if (module === "verifier") {
    state.verifyingKeyRegistry = sharedRefFromChange(findCreatedObject(changes, "::verifier::VerifyingKeyRegistry"));
  }
}
