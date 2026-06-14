import { describe, expect, test } from "bun:test";
import { syncNetwork, syncWebConfig, defaultTargetKeys } from "../test-flow/web-config";

const STATE = {
  packageId: "0xpkg",
  ikaSui: {
    dWalletId: "0xdw",
    dWalletCapObjectId: "0xcap",
    dWalletXOnlyPubkey: "32697b924eeb4c76758383f7ac60e6b87bfd57b8cb2b7a82e7caaf262f2f9908",
  },
  pool: { objectId: "0xpool", initialSharedVersion: 100 },
  commitmentTree: { objectId: "0xtree", initialSharedVersion: 101 },
  btcDepositRegistry: { objectId: "0xdep", initialSharedVersion: 102 },
  utxoSet: { objectId: "0xutxo", initialSharedVersion: 103 },
  nullifierRegistry: { objectId: "0xnull", initialSharedVersion: 104 },
  redemptionQueue: { objectId: "0xq", initialSharedVersion: 105 },
  verifyingKeyRegistry: { objectId: "0xvk", initialSharedVersion: 106 },
  tokenRegistry: { objectId: "0xtok", initialSharedVersion: 107 },
  lightClient: { objectId: "0xlc", initialSharedVersion: 108 },
  redemptionCap: { objectId: "0xrcap", version: 105, digest: "dig" },
  vk: { joinsplit_1x1: { nInputs: 1, nOutputs: 1, nPublic: 4, vkHash: "newhash", registerTxDigest: "newdig" } },
};

function entry(network: string) {
  return {
    chain: "sui",
    bitcoin: { network, poolAddress: "", explorerUrl: "keep-me" },
    sui: {
      rpcUrl: "keep-rpc",
      packageId: "0xOLD",
      eventsPackageId: "0xOLDEVENTS",
      pool: { objectId: "0xOLDPOOL", initialSharedVersion: "1" },
      commitmentTree: { objectId: "x", initialSharedVersion: "1" },
      btcDepositRegistry: { objectId: "x", initialSharedVersion: "1" },
      utxoSet: { objectId: "x", initialSharedVersion: "1" },
      nullifierRegistry: { objectId: "x", initialSharedVersion: "1" },
      redemptionQueue: { objectId: "x", initialSharedVersion: "1" },
      verifyingKeyRegistry: { objectId: "x", initialSharedVersion: "1" },
      tokenRegistry: { objectId: "x", initialSharedVersion: "1" },
      lightClient: { objectId: "x", initialSharedVersion: "1" },
      redemptionCap: { objectId: "x", version: "1", digest: "old" },
      ika: { network: "testnet", dWalletId: "0xOLDDW", dWalletCapObjectId: "0xOLDCAP" },
      vk: { joinsplit_1x1: { nInputs: 1, nOutputs: 1, nPublic: 4, vkHash: "oldhash", registerTxDigest: "olddig" } },
    },
  };
}

describe("syncNetwork", () => {
  const out = syncNetwork(entry("regtest"), STATE);

  test("syncs package + event package", () => {
    expect(out.sui.packageId).toBe("0xpkg");
    expect(out.sui.eventsPackageId).toBe("0xpkg");
  });

  test("syncs object refs with stringified versions", () => {
    expect(out.sui.pool).toEqual({ objectId: "0xpool", initialSharedVersion: "100" });
    expect(out.sui.redemptionCap).toEqual({ objectId: "0xrcap", version: "105", digest: "dig" });
  });

  test("syncs bound dWallet id + cap", () => {
    expect(out.sui.ika.dWalletId).toBe("0xdw");
    expect(out.sui.ika.dWalletCapObjectId).toBe("0xcap");
  });

  test("refreshes vk values without changing the set", () => {
    expect(out.sui.vk.joinsplit_1x1.vkHash).toBe("newhash");
    expect(Object.keys(out.sui.vk)).toEqual(["joinsplit_1x1"]);
  });

  test("derives poolAddress for the network", () => {
    expect(out.bitcoin.poolAddress).toBe(
      "bcrt1pxf5hhyjwadx8vavrs0m6cc8xhpal64acev4h4qh8e2hjvte0nyyq55a3pp",
    );
    expect(syncNetwork(entry("testnet4"), STATE).bitcoin.poolAddress).toBe(
      "tb1pxf5hhyjwadx8vavrs0m6cc8xhpal64acev4h4qh8e2hjvte0nyyqedhh5m",
    );
  });

  test("leaves endpoints untouched", () => {
    expect(out.sui.rpcUrl).toBe("keep-rpc");
    expect(out.bitcoin.explorerUrl).toBe("keep-me");
  });

  test("does not mutate the input", () => {
    const e = entry("regtest");
    syncNetwork(e, STATE);
    expect(e.sui.packageId).toBe("0xOLD");
  });

  test("throws if missing companion in state", () => {
    const bad = { ...STATE, lightClient: undefined };
    expect(() => syncNetwork(entry("regtest"), bad)).toThrow(/lightClient/);
  });
});

describe("syncWebConfig", () => {
  test("syncs only sui keys and reports missing", () => {
    const nets = { "sui-regtest": entry("regtest"), solana: { chain: "solana" } };
    const r = syncWebConfig(nets, STATE, ["sui-regtest", "solana"]);
    expect(r.synced).toEqual(["sui-regtest"]);
    expect(r.missing).toEqual(["solana"]);
    expect(r.nets["sui-regtest"].sui.packageId).toBe("0xpkg");
  });

  test("defaultTargetKeys picks chain=sui entries", () => {
    const nets = { "sui-testnet": entry("testnet4"), "sui-regtest": entry("regtest"), solana: { chain: "solana" } };
    expect(defaultTargetKeys(nets).sort()).toEqual(["sui-regtest", "sui-testnet"]);
  });
});
