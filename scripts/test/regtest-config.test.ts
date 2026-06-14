import { afterEach, describe, expect, test } from "bun:test";
import { loadRegtestConfig } from "../test-flow/regtest-config";

const savedEnv = {
  UTXOPIA_REGTEST_CONFIG: process.env.UTXOPIA_REGTEST_CONFIG,
  UTXOPIA_REGTEST_ESPLORA_URL: process.env.UTXOPIA_REGTEST_ESPLORA_URL,
  UTXOPIA_REGTEST_CONTAINER: process.env.UTXOPIA_REGTEST_CONTAINER,
  UTXOPIA_REGTEST_JOIN_SPLITS: process.env.UTXOPIA_REGTEST_JOIN_SPLITS,
  UTXOPIA_REGTEST_STOP_AFTER_RUN: process.env.UTXOPIA_REGTEST_STOP_AFTER_RUN,
};

afterEach(() => {
  for (const [key, value] of Object.entries(savedEnv)) {
    if (value == null) delete (process.env as any)[key];
    else (process.env as any)[key] = value;
  }
});

describe("regtest config", () => {
  test("loads defaults from yaml and applies env overrides", () => {
    process.env.UTXOPIA_REGTEST_ESPLORA_URL = "http://127.0.0.1:3002/regtest/api";
    process.env.UTXOPIA_REGTEST_CONTAINER = "custom-regtest";
    process.env.UTXOPIA_REGTEST_STOP_AFTER_RUN = "1";

    const config = loadRegtestConfig();

    expect(config.esploraUrl).toBe("http://127.0.0.1:3002/regtest/api");
    expect(config.docker.containerName).toBe("custom-regtest");
    expect(config.bitcoin.wallet).toBe("test");
    expect(config.circuits.joinSplitVariants).toEqual([
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
    ]);
    expect(config.setup.stopAfterRun).toBe(true);
  });

  test("allows local joinsplit registration overrides", () => {
    process.env.UTXOPIA_REGTEST_JOIN_SPLITS = "joinsplit_1x1, joinsplit_2x2";

    const config = loadRegtestConfig();

    expect(config.circuits.joinSplitVariants).toEqual(["joinsplit_1x1", "joinsplit_2x2"]);
  });

  test("rejects joinsplits above current verifier cap", () => {
    process.env.UTXOPIA_REGTEST_JOIN_SPLITS = "joinsplit_6x1";

    expect(() => loadRegtestConfig()).toThrow("n_inputs + n_outputs must be <= 6");
  });
});
