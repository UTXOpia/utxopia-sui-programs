/**
 * Upgrade the utxopia Move package on the active Sui network and sync the
 * new package id into utxopia-sui-state.json and web/src/lib/networks.json.
 *
 * Usage:  bun run scripts/upgrade.ts
 * Env:    UTXOPIA_SUI_GAS_BUDGET   (default 500000000 = 0.5 SUI)
 *         UTXOPIA_SUI_STATE        (default ../utxopia-sui-state.json)
 *
 * Notes:
 * - Uses --skip-verify-compatibility: local Sui CLIs capped below the chain's
 *   protocol version panic in the client-side compatibility check; the chain
 *   still enforces the upgrade policy, so incompatible upgrades fail on-chain.
 * - Published.toml [published.<env>] must hold the CURRENT package id; the
 *   CLI updates it (published-at, version) on success.
 * - Shared objects (pool, tree, registries) survive upgrades; only packageId
 *   changes. Entry calls must use the NEW id, hence the config sync.
 */
import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "..");
const contractsDir = path.join(ROOT, "contracts");
const statePath = process.env.UTXOPIA_SUI_STATE ?? path.join(ROOT, "utxopia-sui-state.json");
const networksPath = path.join(ROOT, "../web/src/lib/networks.json");
const gasBudget = process.env.UTXOPIA_SUI_GAS_BUDGET ?? "500000000";

const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const oldPackageId: string = state.packageId;
const upgradeCap: string = state.upgradeCap.objectId;
if (!oldPackageId || !upgradeCap) throw new Error("state file missing packageId/upgradeCap");

console.log(`Upgrading ${oldPackageId}`);
console.log(`  cap: ${upgradeCap}  gas budget: ${gasBudget}`);

const out = execSync(
  `sui client upgrade --upgrade-capability ${upgradeCap} ` +
  `--gas-budget ${gasBudget} --skip-verify-compatibility --json`,
  { cwd: contractsDir, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);
// The CLI prints build warnings before the JSON payload.
const json = JSON.parse(out.slice(out.indexOf("{")));

const status = json.effects?.status?.status;
if (status !== "success") {
  throw new Error(`upgrade failed: ${JSON.stringify(json.effects?.status)}`);
}
const published = (json.objectChanges ?? []).find((c: { type: string }) => c.type === "published");
if (!published?.packageId) throw new Error("no published package in objectChanges");
const newPackageId: string = published.packageId;
const capChange = (json.objectChanges ?? []).find(
  (c: { objectId?: string }) => c.objectId === upgradeCap,
);

console.log(`Upgrade tx: ${json.digest}`);
console.log(`New package: ${newPackageId}`);

state.packageId = newPackageId;
if (capChange) {
  state.upgradeCap.version = String(capChange.version);
  state.upgradeCap.digest = capChange.digest;
}
fs.writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n");
console.log(`Updated ${path.relative(process.cwd(), statePath)}`);

if (fs.existsSync(networksPath)) {
  const nets = JSON.parse(fs.readFileSync(networksPath, "utf8"));
  const touched: string[] = [];
  for (const [name, net] of Object.entries<Record<string, { packageId?: string }>>(nets)) {
    if (net.sui?.packageId === oldPackageId) {
      net.sui.packageId = newPackageId;
      touched.push(name);
    }
  }
  fs.writeFileSync(networksPath, JSON.stringify(nets, null, 2) + "\n");
  console.log(`Updated web networks.json: ${touched.join(", ") || "(no blocks matched)"}`);
} else {
  console.log("web networks.json not found — update packageId manually");
}
