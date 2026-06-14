#!/usr/bin/env bun
// Register native SUI (Coin<0x2::sui::SUI>) in the shielded-pool token registry.
// Resolves CoinMetadata<SUI> from RPC (no hand-entered decimals), then calls the
// admin-gated token_registry::register_token<T>. Amounts are in MIST (9 decimals).
//
// Env overrides (all MIST, except fee in bps):
//   SUI_MIN_DEPOSIT  default 100_000_000        (0.1 SUI)
//   SUI_MAX_DEPOSIT  default 1_000_000_000_000  (1,000 SUI)
//   SUI_DEPOSIT_CAP  default 100_000_000_000_000 (100,000 SUI)
//   SUI_FEE_BPS      default 0
import { spawnSync } from "node:child_process";
import { ROOT, parseJsonFromStdout, readState, requireState, stateFile, writeState } from "./shared";

const COIN_TYPE = "0x2::sui::SUI";
const gasBudget = process.env.UTXOPIA_SUI_GAS_BUDGET ?? "100000000";
const minDeposit = process.env.SUI_MIN_DEPOSIT ?? "100000000";
const maxDeposit = process.env.SUI_MAX_DEPOSIT ?? "1000000000000";
const depositCap = process.env.SUI_DEPOSIT_CAP ?? "100000000000000";
const feeBps = process.env.SUI_FEE_BPS ?? "0";

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const adminCap = requireState(state.adminCap, "adminCap");
const registry = requireState(state.tokenRegistry, "tokenRegistry (run init-token-registry.ts first)");
const rpcUrl = state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";

const metadataId = await resolveCoinMetadata(COIN_TYPE);
console.log(`CoinMetadata<${COIN_TYPE}> = ${metadataId}`);

const result = spawnSync("sui", [
  "client", "call",
  "--package", packageId,
  "--module", "token_registry",
  "--function", "register_token",
  "--type-args", COIN_TYPE,
  "--args", adminCap.objectId, pool.objectId, registry.objectId, metadataId,
  minDeposit, maxDeposit, depositCap, feeBps,
  "--gas-budget", gasBudget,
  "--json",
], { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

if (result.status !== 0) {
  console.error(result.stderr || result.stdout);
  process.exit(result.status ?? 1);
}

const output = parseJsonFromStdout(result.stdout) as any;
state.registeredTokens = state.registeredTokens ?? {};
state.registeredTokens[COIN_TYPE] = {
  coinType: COIN_TYPE,
  metadataId,
  minDeposit,
  maxDeposit,
  depositCap,
  feeBps: Number(feeBps),
  registerTxDigest: output.digest,
};
writeState(state);
console.log(`Wrote ${stateFile()}`);
console.log(JSON.stringify({ registered: state.registeredTokens[COIN_TYPE] }, null, 2));

async function resolveCoinMetadata(coinType: string): Promise<string> {
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "suix_getCoinMetadata", params: [coinType] }),
  });
  const json = (await res.json()) as any;
  const id = json?.result?.id;
  if (!id) throw new Error(`Could not resolve CoinMetadata for ${coinType}: ${JSON.stringify(json)}`);
  return id;
}
