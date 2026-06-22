#!/usr/bin/env bun
/**
 * Sui regtest faucet relay service (host-run).
 *
 * The web faucet route (`web/src/app/api/faucet/regtest/route.ts`) computes the
 * BTC deposit address + compact OP_RETURN in the SDK (no Docker needed) and, when
 * running on Vercel, forwards `{ address, amountSats, opReturn }` to
 * `${REGTEST_FAUCET_BACKEND_URL}/api/faucet/regtest`. Vercel can't reach the local
 * regtest node or run the relay, so this process implements that backend endpoint
 * on the machine that DOES have them: it broadcasts the deposit + mines, then runs
 * `relay-deposit.ts` to SPV-verify and `complete_deposit` on the Sui pool.
 *
 * It deliberately holds no extra secrets the web app doesn't already have — it
 * reuses the host's regtest node (via `docker exec`) and the Sui relayer key
 * (whatever `relay-deposit.ts` already uses). Expose it publicly via a Cloudflare
 * tunnel (e.g. faucet.utxopia.com → http://host.docker.internal:8790).
 *
 * Env:
 *   FAUCET_PORT                 default 8790
 *   FAUCET_API_KEY / BACKEND_API_KEY   shared secret; required in X-API-Key (set to enable auth)
 *   REGTEST_FAUCET_CONFIRMATIONS       blocks mined after the deposit (default 6)
 *   REGTEST_FAUCET_AUTOMINE            "0" disables the 101-block bootstrap mine
 *   REGTEST_FAUCET_MAX_SATS            cap per request (default 100000)
 *   ESPLORA_URL / UTXOPIA_SUI_RPC_URL  passed through to relay-deposit.ts
 */

import { spawn } from "node:child_process";
import * as path from "node:path";
import { ROOT } from "./shared";
import {
  bitcoinCli,
  createOpReturnTx,
  getNewAddress,
  mineBlocks,
} from "./lib/regtest-helpers";

const PORT = Number(process.env.FAUCET_PORT || "8790");
const API_KEY = (process.env.FAUCET_API_KEY || process.env.BACKEND_API_KEY || "").trim();
const CONFIRMATIONS = Math.max(1, Number(process.env.REGTEST_FAUCET_CONFIRMATIONS || "6"));
const AUTOMINE = process.env.REGTEST_FAUCET_AUTOMINE !== "0";
const MAX_SATS = Math.max(1, Number(process.env.REGTEST_FAUCET_MAX_SATS || "100000"));
const RELAY_TIMEOUT_MS = Number(process.env.REGTEST_FAUCET_SUI_RELAY_TIMEOUT_MS || "120000");
const BOOTSTRAP_BLOCKS = 101;

interface FaucetRequest {
  address?: string;
  stealthAddress?: string;
  amountSats?: number;
  opReturn?: string;
}

interface RelayResult {
  ok: boolean;
  txDigest?: string;
  error?: string;
  depositVout?: number;
  commitment?: string;
  root?: string;
}

let walletFunded = false;

function ensureWalletFunded(): string | null {
  if (walletFunded) return null;
  let balanceBtc = NaN;
  try {
    balanceBtc = Number(bitcoinCli("getbalance"));
  } catch (e) {
    return `getbalance failed: ${e instanceof Error ? e.message : String(e)}`;
  }
  if (Number.isFinite(balanceBtc) && balanceBtc > 0) {
    walletFunded = true;
    return null;
  }
  if (!AUTOMINE) return "wallet has zero spendable balance and AUTOMINE is disabled";
  try {
    const miner = getNewAddress();
    console.log(`[faucet] bootstrapping: mining ${BOOTSTRAP_BLOCKS} blocks to ${miner}`);
    mineBlocks(BOOTSTRAP_BLOCKS, miner);
    walletFunded = true;
    return null;
  } catch (e) {
    return `bootstrap mining failed: ${e instanceof Error ? e.message : String(e)}`;
  }
}

function parseJsonObjectFromStdout(stdout: string): RelayResult {
  const start = stdout.indexOf("{");
  const end = stdout.lastIndexOf("}");
  if (start < 0 || end < start) throw new Error(`no JSON object in relay output: ${stdout.slice(0, 400)}`);
  return JSON.parse(stdout.slice(start, end + 1)) as RelayResult;
}

function relaySuiDeposit(input: {
  txid: string;
  amountSats: number;
  opReturnHex: string;
  depositAddress: string;
}): Promise<RelayResult> {
  const script = path.join(ROOT, "sui-programs/scripts/relay-deposit.ts");
  const bunBin = process.env.BUN_BIN || "bun";
  const args = [
    script,
    "--txid", input.txid,
    "--amount-sats", String(input.amountSats),
    "--op-return", input.opReturnHex,
    "--deposit-address", input.depositAddress,
  ];
  return new Promise((resolve) => {
    const child = spawn(bunBin, args, { cwd: ROOT, env: process.env });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), RELAY_TIMEOUT_MS);
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("close", () => {
      clearTimeout(timer);
      try {
        const parsed = parseJsonObjectFromStdout(stdout);
        resolve({ ...parsed, ok: parsed.ok === true });
      } catch (e) {
        resolve({
          ok: false,
          error: (e instanceof Error ? e.message : String(e)) + (stderr ? ` | stderr: ${stderr.slice(0, 400)}` : ""),
        });
      }
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, error: e.message });
    });
  });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function handleFaucet(req: Request): Promise<Response> {
  if (API_KEY) {
    const provided = req.headers.get("x-api-key");
    if (provided !== API_KEY) return json({ ok: false, error: "missing or invalid X-API-Key" }, 401);
  }

  let body: FaucetRequest;
  try {
    body = (await req.json()) as FaucetRequest;
  } catch {
    return json({ ok: false, error: "invalid JSON body" }, 400);
  }

  const address = (body.address ?? "").trim();
  const opReturnHex = (body.opReturn ?? "").trim();
  const amountSats = Number(body.amountSats);

  if (!/^bcrt1[a-z0-9]{38,90}$/.test(address)) {
    return json({ ok: false, error: "address must be a regtest bech32 (bcrt1…) deposit address" }, 400);
  }
  if (!opReturnHex || !/^[0-9a-fA-F]+$/.test(opReturnHex) || opReturnHex.length % 2 !== 0) {
    return json({ ok: false, error: "opReturn must be a hex string (the compact deposit payload)" }, 400);
  }
  if (!Number.isInteger(amountSats) || amountSats <= 0 || amountSats > MAX_SATS) {
    return json({ ok: false, error: `amountSats must be an integer from 1..${MAX_SATS}` }, 400);
  }

  const bootstrapErr = ensureWalletFunded();
  if (bootstrapErr) return json({ ok: false, error: bootstrapErr }, 502);

  let txid: string;
  try {
    txid = createOpReturnTx(address, amountSats, opReturnHex);
  } catch (e) {
    return json({ ok: false, error: `broadcast failed: ${e instanceof Error ? e.message : String(e)}` }, 502);
  }

  let blocksMined = 0;
  let minerAddress = "";
  try {
    minerAddress = getNewAddress();
    mineBlocks(CONFIRMATIONS, minerAddress);
    blocksMined = CONFIRMATIONS;
  } catch (e) {
    return json({ ok: true, txid, warning: `sent but failed to mine: ${e instanceof Error ? e.message : String(e)}` });
  }

  const suiDeposit = await relaySuiDeposit({ txid, amountSats, opReturnHex, depositAddress: address });

  return json({
    ok: true,
    txid,
    mode: "utxo_airdrop",
    depositAddress: address,
    opReturn: opReturnHex,
    amountSats,
    blocksMined,
    minerAddress,
    suiDeposit,
  });
}

const server = Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && (url.pathname === "/health" || url.pathname === "/")) {
      return json({ ok: true, service: "sui-regtest-faucet", authRequired: Boolean(API_KEY) });
    }
    if (req.method === "POST" && url.pathname === "/api/faucet/regtest") {
      try {
        return await handleFaucet(req);
      } catch (e) {
        return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
      }
    }
    return json({ ok: false, error: "not found" }, 404);
  },
});

console.log(
  `[faucet] Sui regtest faucet relay listening on http://localhost:${server.port}` +
    ` (auth ${API_KEY ? "ON" : "OFF — set FAUCET_API_KEY"}, confirmations=${CONFIRMATIONS})`,
);
