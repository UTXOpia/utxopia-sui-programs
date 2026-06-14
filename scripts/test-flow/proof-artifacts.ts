import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { ROOT } from "../shared";

export interface ProofArtifacts {
  tmpDir: string;
  proofPath: string;
  publicPath: string;
}

export interface SuiProofExport {
  proofPoints: string;
  publicInputs: string;
}

export function defaultCircuitsDir(): string {
  return process.env.UTXOPIA_CIRCUITS_DIR
    ? path.resolve(process.env.UTXOPIA_CIRCUITS_DIR)
    : path.resolve(ROOT, "../utxopia-circuits");
}

export function generateProof(
  circuit: string,
  inputs: Record<string, unknown>,
  options: { tmpPrefix?: string; circuitsDir?: string } = {},
): ProofArtifacts {
  const circuitsDir = options.circuitsDir ?? defaultCircuitsDir();
  const circuitDir = path.join(circuitsDir, "build", circuit);
  const wasmPath = path.join(circuitDir, `${circuit}_js`, `${circuit}.wasm`);
  const zkeyPath = path.join(circuitDir, `${circuit}.zkey`);
  if (!existsSync(wasmPath)) {
    throw new Error(`Missing circuit WASM: ${wasmPath}`);
  }
  if (!existsSync(zkeyPath)) {
    throw new Error(`Missing circuit zkey: ${zkeyPath}`);
  }

  const tmpDir = path.join(ROOT, ".tmp", `${options.tmpPrefix ?? circuit}-${Date.now()}`);
  mkdirSync(tmpDir, { recursive: true });
  const inputPath = path.join(tmpDir, "input.json");
  const proofPath = path.join(tmpDir, "proof.json");
  const publicPath = path.join(tmpDir, "public.json");
  const runnerPath = path.join(tmpDir, "prove.cjs");
  writeFileSync(inputPath, JSON.stringify(inputs));
  writeFileSync(runnerPath, `
const fs = require("fs");
const snarkjs = require("snarkjs");
(async () => {
  const input = JSON.parse(fs.readFileSync(${JSON.stringify(inputPath)}, "utf8"));
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    ${JSON.stringify(wasmPath)},
    ${JSON.stringify(zkeyPath)}
  );
  fs.writeFileSync(${JSON.stringify(proofPath)}, JSON.stringify(proof));
  fs.writeFileSync(${JSON.stringify(publicPath)}, JSON.stringify(publicSignals));
  process.exit(0);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
`);

  execFileSync("node", [runnerPath], {
    cwd: ROOT,
    stdio: "inherit",
    timeout: Number(process.env.UTXOPIA_SUI_PROVE_TIMEOUT_MS ?? "300000"),
  });
  return { tmpDir, proofPath, publicPath };
}

export function verifyProof(
  circuit: string,
  proofPath: string,
  publicPath: string,
  options: { circuitsDir?: string } = {},
) {
  const circuitsDir = options.circuitsDir ?? defaultCircuitsDir();
  const vkeyPath = path.join(circuitsDir, "build", circuit, `${circuit}.vkey.json`);
  const runnerPath = path.join(path.dirname(proofPath), "verify.cjs");
  writeFileSync(runnerPath, `
const fs = require("fs");
const snarkjs = require("snarkjs");
(async () => {
  const vkey = JSON.parse(fs.readFileSync(${JSON.stringify(vkeyPath)}, "utf8"));
  const proof = JSON.parse(fs.readFileSync(${JSON.stringify(proofPath)}, "utf8"));
  const publicSignals = JSON.parse(fs.readFileSync(${JSON.stringify(publicPath)}, "utf8"));
  const ok = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  if (!ok) throw new Error("snarkjs rejected generated proof");
  process.exit(0);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
`);
  execFileSync("node", [runnerPath], {
    cwd: ROOT,
    stdio: "inherit",
    timeout: Number(process.env.UTXOPIA_SUI_PROVE_TIMEOUT_MS ?? "300000"),
  });
}

export function exportSuiProof(proofPath: string, publicPath: string): SuiProofExport {
  const result = spawnSync("cargo", [
    "run",
    "--quiet",
    "--manifest-path",
    path.join(ROOT, "../utxopia-circuits/sui-groth16-exporter/Cargo.toml"),
    "--",
    "proof",
    "--proof",
    proofPath,
    "--public",
    publicPath,
  ], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: Number(process.env.UTXOPIA_SUI_EXPORT_TIMEOUT_MS ?? "300000"),
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to export Sui Groth16 proof");
  }
  return JSON.parse(result.stdout.trim()) as SuiProofExport;
}

export function cleanupProof(tmpDir: string) {
  if (process.env.UTXOPIA_SUI_KEEP_PROOF_TMP === "1") {
    return;
  }
  rmSync(tmpDir, { recursive: true, force: true });
}
