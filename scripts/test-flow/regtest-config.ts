import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { ROOT } from "../shared";

export interface RegtestConfig {
  esploraUrl: string;
  circuits: {
    joinSplitVariants: string[];
  };
  docker: {
    composeFile: string;
    containerName: string;
  };
  bitcoin: {
    cliPath: string;
    dataDir: string;
    wallet: string;
  };
  setup: {
    mineMaturityBlocks: number;
    waitTimeoutMs: number;
    stopAfterRun: boolean;
  };
}

const DEFAULT_CONFIG: RegtestConfig = {
  esploraUrl: "http://localhost:3002/regtest/api",
  circuits: {
    joinSplitVariants: [
      "joinsplit_1x1",
      "joinsplit_1x2",
      "joinsplit_1x3",
      "joinsplit_1x4",
      "joinsplit_1x5",
      "joinsplit_2x1",
      "joinsplit_2x2",
      "joinsplit_2x3",
      "joinsplit_2x4",
      "joinsplit_3x1",
      "joinsplit_3x2",
      "joinsplit_3x3",
      "joinsplit_4x1",
      "joinsplit_4x2",
      "joinsplit_5x1",
    ],
  },
  docker: {
    composeFile: "docker-compose.regtest.yml",
    containerName: "utxopia-esplora-regtest",
  },
  bitcoin: {
    cliPath: "/srv/explorer/bitcoin/bin/bitcoin-cli",
    dataDir: "/data/bitcoin",
    wallet: "test",
  },
  setup: {
    mineMaturityBlocks: 101,
    waitTimeoutMs: 120_000,
    stopAfterRun: false,
  },
};

export function regtestConfigPath(): string {
  if (process.env.UTXOPIA_REGTEST_CONFIG) return path.resolve(process.env.UTXOPIA_REGTEST_CONFIG);
  const preferred = path.join(ROOT, "config/regtest.yaml");
  return existsSync(preferred) ? preferred : path.join(ROOT, "regtest.config.yaml");
}

export function loadRegtestConfig(): RegtestConfig {
  const config = structuredClone(DEFAULT_CONFIG);
  const file = regtestConfigPath();
  if (existsSync(file)) {
    mergeConfig(config, parseSimpleYaml(readFileSync(file, "utf8")));
  }

  config.esploraUrl = process.env.ESPLORA_URL ?? process.env.UTXOPIA_REGTEST_ESPLORA_URL ?? config.esploraUrl;
  config.docker.composeFile = process.env.UTXOPIA_REGTEST_COMPOSE_FILE ?? config.docker.composeFile;
  config.docker.containerName = process.env.UTXOPIA_REGTEST_CONTAINER ?? config.docker.containerName;
  config.bitcoin.cliPath = process.env.UTXOPIA_REGTEST_BITCOIN_CLI ?? config.bitcoin.cliPath;
  config.bitcoin.dataDir = process.env.UTXOPIA_REGTEST_BITCOIN_DATADIR ?? config.bitcoin.dataDir;
  config.bitcoin.wallet = process.env.UTXOPIA_REGTEST_BITCOIN_WALLET ?? config.bitcoin.wallet;
  config.circuits.joinSplitVariants = listEnv(
    "UTXOPIA_REGTEST_JOIN_SPLITS",
    config.circuits.joinSplitVariants,
  );
  config.setup.mineMaturityBlocks = numberEnv("UTXOPIA_REGTEST_MATURITY_BLOCKS", config.setup.mineMaturityBlocks);
  config.setup.waitTimeoutMs = numberEnv("UTXOPIA_REGTEST_WAIT_TIMEOUT_MS", config.setup.waitTimeoutMs);
  config.setup.stopAfterRun = boolEnv("UTXOPIA_REGTEST_STOP_AFTER_RUN", config.setup.stopAfterRun);

  validateJoinSplitVariants(config.circuits.joinSplitVariants);
  return config;
}

export function resolveComposeFile(config: RegtestConfig): string {
  return path.isAbsolute(config.docker.composeFile)
    ? config.docker.composeFile
    : path.join(ROOT, config.docker.composeFile);
}

function mergeConfig(target: Record<string, any>, source: Record<string, any>) {
  for (const [key, value] of Object.entries(source)) {
    if (value && typeof value === "object" && !Array.isArray(value) && key in target) {
      mergeConfig((target as any)[key], value);
    } else if (key in target) {
      (target as any)[key] = value;
    }
  }
}

function parseSimpleYaml(input: string): Record<string, any> {
  const root: Record<string, any> = {};
  const stack: Array<{
    indent: number;
    value: Record<string, any> | any[];
    parent?: Record<string, any>;
    key?: string;
  }> = [{ indent: -1, value: root }];

  for (const rawLine of input.split(/\r?\n/)) {
    const withoutComment = rawLine.replace(/\s+#.*$/, "");
    if (!withoutComment.trim() || withoutComment.trimStart().startsWith("#")) continue;

    const indent = withoutComment.match(/^ */)?.[0].length ?? 0;
    while (stack.length > 1 && indent <= stack[stack.length - 1].indent) stack.pop();
    const parentFrame = stack[stack.length - 1];
    const parent = parentFrame.value;

    const listMatch = withoutComment.trim().match(/^-\s+(.+)$/);
    if (listMatch) {
      const list = ensureArrayFrame(parentFrame, rawLine);
      list.push(parseScalar(listMatch[1]));
      continue;
    }

    if (Array.isArray(parent)) {
      throw new Error(`Unsupported YAML line in ${regtestConfigPath()}: ${rawLine}`);
    }

    const match = withoutComment.trim().match(/^([A-Za-z0-9_-]+):(?:\s*(.*))?$/);
    if (!match) {
      throw new Error(`Unsupported YAML line in ${regtestConfigPath()}: ${rawLine}`);
    }

    const key = match[1];
    const rawValue = match[2] ?? "";
    if (rawValue === "") {
      const child: Record<string, any> = {};
      parent[key] = child;
      stack.push({ indent, value: child, parent, key });
    } else {
      parent[key] = parseScalar(rawValue);
    }
  }

  return root;
}

function ensureArrayFrame(
  frame: { value: Record<string, any> | any[]; parent?: Record<string, any>; key?: string },
  rawLine: string,
): any[] {
  if (Array.isArray(frame.value)) return frame.value;
  if (!frame.parent || !frame.key || Object.keys(frame.value).length !== 0) {
    throw new Error(`Unsupported YAML list in ${regtestConfigPath()}: ${rawLine}`);
  }

  const list: any[] = [];
  frame.parent[frame.key] = list;
  frame.value = list;
  return list;
}

function parseScalar(value: string): string | number | boolean | string[] {
  const trimmed = value.trim();
  if (trimmed === "true") return true;
  if (trimmed === "false") return false;
  if (/^-?\d+$/.test(trimmed)) return Number(trimmed);
  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    return trimmed
      .slice(1, -1)
      .split(",")
      .map((item) => item.trim().replace(/^["']|["']$/g, ""))
      .filter(Boolean);
  }
  return trimmed.replace(/^["']|["']$/g, "");
}

function numberEnv(name: string, fallback: number): number {
  const value = process.env[name];
  if (value == null || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`${name} must be a number`);
  return parsed;
}

function boolEnv(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value == null || value === "") return fallback;
  if (value === "1" || value === "true") return true;
  if (value === "0" || value === "false") return false;
  throw new Error(`${name} must be true/false or 1/0`);
}

function listEnv(name: string, fallback: string[]): string[] {
  const value = process.env[name];
  if (value == null || value.trim() === "") return fallback;
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function validateJoinSplitVariants(variants: string[]) {
  if (!Array.isArray(variants) || variants.length === 0) {
    throw new Error("circuits.joinSplitVariants must contain at least one joinsplit_NxM circuit");
  }

  const seen = new Set<string>();
  for (const variant of variants) {
    const match = variant.match(/^joinsplit_(\d+)x(\d+)$/);
    if (!match) throw new Error(`Invalid joinsplit circuit name: ${variant}`);
    const nInputs = Number(match[1]);
    const nOutputs = Number(match[2]);
    if (nInputs < 1 || nOutputs < 1) throw new Error(`Invalid joinsplit arity: ${variant}`);
    if (nInputs + nOutputs > 6) {
      throw new Error(`${variant} exceeds current Sui verifier cap: n_inputs + n_outputs must be <= 6`);
    }
    if (seen.has(variant)) throw new Error(`Duplicate joinsplit circuit in config: ${variant}`);
    seen.add(variant);
  }
}
