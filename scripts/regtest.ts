#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { stateFile } from "./shared";
import { loadRegtestConfig } from "./test-flow/regtest-config";
import {
  prepareRegtestEnvironment,
  startRegtestDocker,
  stopRegtestDocker,
} from "./lib/regtest-helpers";

const command = process.argv[2];
const flags = new Set(process.argv.slice(3));
const config = loadRegtestConfig();

if (!command || command === "help" || command === "--help") {
  console.log([
    "Usage:",
    "  bun scripts/regtest.ts start",
    "  bun scripts/regtest.ts stop",
    "  bun scripts/regtest.ts run --existing",
    "  bun scripts/regtest.ts run --start [--stop-after]",
    "  bun scripts/regtest.ts run --existing --reset-sui",
    "",
    "Config:",
    "  config/regtest.yaml, legacy regtest.config.yaml, or UTXOPIA_REGTEST_CONFIG=/path/to/file",
  ].join("\n"));
  process.exit(0);
}

if (command === "start") {
  await prepareRegtestEnvironment({ startDocker: true });
  process.exit(0);
}

if (command === "stop") {
  stopRegtestDocker();
  process.exit(0);
}

if (command !== "run") {
  throw new Error("Usage: bun scripts/regtest.ts [run|start|stop] [--start] [--existing] [--stop-after]");
}

const startDocker = flags.has("--start") && !flags.has("--existing");
const stopAfter = flags.has("--stop-after") || config.setup.stopAfterRun;
const resetSui = flags.has("--reset-sui");

try {
  await prepareRegtestEnvironment({ startDocker });
  if (resetSui) {
    prepareFreshSuiState();
  }

  const child = runBun(["scripts/regtest-flow.ts"]);
  if (child.status !== 0) {
    process.exitCode = child.status ?? 1;
  }
} finally {
  if (stopAfter) {
    stopRegtestDocker();
  }
}

function prepareFreshSuiState() {
  backupState();
  runChecked("deploy", ["scripts/deploy.ts"]);
  runChecked("init", ["scripts/init.ts"]);
  runChecked("init token registry", ["scripts/init-token-registry.ts"]);
  for (const variant of config.circuits.joinSplitVariants) {
    runChecked(`register vk ${variant}`, ["scripts/register-vkey.ts", variant]);
  }
}

function backupState() {
  const file = stateFile();
  if (!existsSync(file)) return;
  const backupDir = path.join(process.cwd(), ".tmp/state-backups");
  mkdirSync(backupDir, { recursive: true });
  const backup = path.join(
    backupDir,
    `${path.basename(file)}.pre-regtest-reset-${new Date().toISOString().replace(/[:.]/g, "-")}.bak`,
  );
  copyFileSync(file, backup);
  console.log(`Backed up ${file} -> ${backup}`);
}

function runChecked(label: string, args: string[]) {
  console.log(`\n== ${label} ==`);
  const result = runBun(args);
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function runBun(args: string[]) {
  return spawnSync("bun", args, {
    cwd: process.cwd(),
    stdio: "inherit",
    env: {
      ...process.env,
      ESPLORA_URL: process.env.ESPLORA_URL ?? config.esploraUrl,
    },
  });
}
