#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { ROOT, objectRefFromChange, parseJsonFromStdout, readState, stateFile, writeState } from "./shared";
import path from "node:path";
import { existsSync, unlinkSync } from "node:fs";

const network = process.env.UTXOPIA_SUI_NETWORK ?? "testnet";
const gasBudget = process.env.UTXOPIA_SUI_GAS_BUDGET ?? "200000000";
const packagePath = path.join(ROOT, "chains/sui/contracts");
const publishedFile = path.join(packagePath, "Published.toml");

if (existsSync(publishedFile)) {
  unlinkSync(publishedFile);
}

const result = spawnSync("sui", [
  "client",
  "publish",
  packagePath,
  "--gas-budget",
  gasBudget,
  "--json",
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
const objectChanges = output.objectChanges ?? [];
const published = objectChanges.find((change: any) => change.type === "published");
const upgradeCapChange = objectChanges.find((change: any) =>
  change.type === "created" && typeof change.objectType === "string" && change.objectType === "0x2::package::UpgradeCap"
);

if (!published?.packageId) {
  throw new Error("Could not find published packageId in Sui publish output");
}

const state = readState();
state.network = network;
state.packageId = published.packageId;
state.upgradeCap = objectRefFromChange(upgradeCapChange);
delete state.adminCap;
delete state.pool;
delete state.btcDepositRegistry;
delete state.nullifierRegistry;
delete state.redemptionQueue;
delete state.redemptionCap;
delete state.verifyingKeyRegistry;
delete state.vk;
delete state.lastRedemption;
delete state.lastTransact;
writeState(state);

console.log(`Wrote ${stateFile()}`);
console.log(JSON.stringify({
  packageId: state.packageId,
  upgradeCap: state.upgradeCap,
}, null, 2));
