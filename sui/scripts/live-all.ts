#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { readState } from "./shared";

const fresh = process.argv.includes("--fresh") || process.env.UTXOPIA_SUI_FRESH === "1";
const forceVk = fresh || process.env.UTXOPIA_SUI_FORCE_VK === "1";

if (fresh) {
  run("sui:poc:deploy");
  run("sui:poc:init");
}

const state = readState();
if (forceVk || !state.vk?.joinsplit_1x1?.registerTxDigest) {
  run("sui:poc:register-vkey", ["joinsplit_1x1"]);
}

run("sui:poc:live-transact");
run("sui:poc:live-core");

function run(script: string, args: string[] = []) {
  console.log(`\n==> ${script}${args.length ? ` ${args.join(" ")}` : ""}`);
  const result = spawnSync("bun", ["run", script, ...args], {
    stdio: "inherit",
    env: process.env,
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
