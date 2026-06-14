#!/usr/bin/env bun
// Initialize the generic Coin<T> shielded-pool token registry and pin it to the Pool.
// Additive to a deployed pool (init.ts predates the token registry); set-once via the
// `already_bound`-guarded pool::set_token_registry_id companion setter.
import { spawnSync } from "node:child_process";
import {
  ROOT,
  findCreatedObject,
  objectRefFromChange,
  parseJsonFromStdout,
  readState,
  requireState,
  sharedRefFromChange,
  stateFile,
  writeState,
} from "./shared";

const gasBudget = process.env.UTXOPIA_SUI_GAS_BUDGET ?? "100000000";
const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const adminCap = requireState(state.adminCap, "adminCap");

if (state.tokenRegistry) {
  console.log(`Token registry already initialized: ${state.tokenRegistry.objectId}`);
  process.exit(0);
}

const regCh = call("token_registry", "initialize_registry", []);
state.tokenRegistry = sharedRefFromChange(findCreatedObject(regCh, "::token_registry::TokenRegistry"));
const registry = requireState(state.tokenRegistry, "tokenRegistry (created)");

callWithAdminCap("pool", "set_token_registry_id", [adminCap.objectId, pool.objectId, registry.objectId]);

writeState(state);
console.log(`Wrote ${stateFile()}`);
console.log(JSON.stringify({ tokenRegistry: state.tokenRegistry }, null, 2));

function callWithAdminCap(module: string, fn: string, args: string[]) {
  const changes = call(module, fn, args);
  const adminChange = changes.find((change: any) =>
    change.objectId === state.adminCap?.objectId && (change.type === "mutated" || change.type === "created")
  );
  state.adminCap = objectRefFromChange(adminChange) ?? state.adminCap;
}

function call(module: string, fn: string, args: string[]): any[] {
  const result = spawnSync("sui", [
    "client", "call",
    "--package", packageId,
    "--module", module,
    "--function", fn,
    "--gas-budget", gasBudget,
    "--json",
    ...(args.length ? ["--args", ...args] : []),
  ], { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

  if (result.status !== 0) {
    console.error(result.stderr || result.stdout);
    process.exit(result.status ?? 1);
  }
  const output = parseJsonFromStdout(result.stdout) as any;
  return output.objectChanges ?? [];
}
