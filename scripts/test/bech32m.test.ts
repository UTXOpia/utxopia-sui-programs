import { describe, expect, test } from "bun:test";
import { hrpForNetwork, p2trAddress } from "../lib/bech32m";

// The pool's bound dWallet x-only key (state.ikaSui.dWalletXOnlyPubkey).
const POOL_XONLY = "32697b924eeb4c76758383f7ac60e6b87bfd57b8cb2b7a82e7caaf262f2f9908";

describe("bech32m P2TR derivation", () => {
  test("derives the pool address for the bound dWallet key per network", () => {
    expect(p2trAddress(POOL_XONLY, "testnet4")).toBe(
      "tb1pxf5hhyjwadx8vavrs0m6cc8xhpal64acev4h4qh8e2hjvte0nyyqedhh5m",
    );
    expect(p2trAddress(POOL_XONLY, "regtest")).toBe(
      "bcrt1pxf5hhyjwadx8vavrs0m6cc8xhpal64acev4h4qh8e2hjvte0nyyq55a3pp",
    );
    expect(p2trAddress(POOL_XONLY, "mainnet")).toBe(
      "bc1pxf5hhyjwadx8vavrs0m6cc8xhpal64acev4h4qh8e2hjvte0nyyqw9pcw5",
    );
  });

  test("accepts a 0x-prefixed key", () => {
    expect(p2trAddress("0x" + POOL_XONLY, "regtest")).toBe(
      p2trAddress(POOL_XONLY, "regtest"),
    );
  });

  test("maps networks to HRPs", () => {
    expect(hrpForNetwork("mainnet")).toBe("bc");
    expect(hrpForNetwork("regtest")).toBe("bcrt");
    expect(hrpForNetwork("testnet4")).toBe("tb");
    expect(() => hrpForNetwork("nope")).toThrow();
  });

  test("rejects a non-32-byte program", () => {
    expect(() => p2trAddress("abcd", "regtest")).toThrow();
  });
});
