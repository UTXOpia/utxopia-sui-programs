#!/usr/bin/env bun
/**
 * Generate the web `networks.json` Sui blocks from the canonical deploy state
 * (utxopia-sui-state.json) so web never hand-defines deployment values. Phase 1
 * of docs/config-centralization-plan.md — the fix for the config-drift class.
 *
 * Usage:
 *   bun scripts/export-web-config.ts [networkKey...]   # write (default: all sui-* keys)
 *   bun scripts/export-web-config.ts --check [keys...]  # CI guard: exit 1 on drift, no write
 *
 * Syncs deployment IDENTITY (packageId, eventsPackageId, pool + all companion
 * object refs, redemptionCap, bound dWallet id/cap, vk hashes) and DERIVES
 * bitcoin.poolAddress from the bound dWallet key. Leaves endpoints
 * (rpcUrl/explorerUrl/Ika infra ids) untouched.
 */
import fs from "node:fs";
import path from "node:path";
import { ROOT, readState } from "./shared";
import { syncWebConfig, defaultTargetKeys } from "./test-flow/web-config";

const networksPath =
  process.env.UTXOPIA_WEB_NETWORKS ?? path.join(ROOT, "../web/src/lib/networks.json");

const argv = process.argv.slice(2);
const check = argv.includes("--check");
const keysArg = argv.filter((a) => !a.startsWith("--"));

if (!fs.existsSync(networksPath)) {
  console.error(`web networks.json not found at ${networksPath}`);
  process.exit(1);
}

const state = readState();
const before = fs.readFileSync(networksPath, "utf8");
const nets = JSON.parse(before);
const keys = keysArg.length ? keysArg : defaultTargetKeys(nets);

const { nets: synced, synced: touched, missing } = syncWebConfig(nets, state, keys);
if (missing.length) {
  console.error(`no \`sui\` block for: ${missing.join(", ")}`);
  process.exit(1);
}

const after = JSON.stringify(synced, null, 2) + "\n";

if (check) {
  if (after !== before) {
    console.error(
      `web networks.json is OUT OF SYNC with deploy state (${touched.join(", ")}).\n` +
        `Run: bun scripts/export-web-config.ts`,
    );
    process.exit(1);
  }
  console.log(`web networks.json in sync (${touched.join(", ")})`);
  process.exit(0);
}

if (after === before) {
  console.log(`web networks.json already in sync (${touched.join(", ")})`);
  process.exit(0);
}

fs.writeFileSync(networksPath, after);
console.log(`Updated ${path.relative(process.cwd(), networksPath)}: ${touched.join(", ")}`);
console.log(`  packageId = ${state.packageId}`);
