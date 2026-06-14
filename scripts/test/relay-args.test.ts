import { describe, expect, test } from "bun:test";
import { parseRelayArgs } from "../test-flow/relay-args";

const txid = "aa".repeat(32);
const opReturn = "11".repeat(73);

describe("relay argument parsing", () => {
  test("parses valid relay args", () => {
    const args = parseRelayArgs([
      "--txid", txid.toUpperCase(),
      "--amount-sats", "25000",
      "--op-return", opReturn,
      "--deposit-vout", "2",
      "--deposit-address", "bcrt1qtesttesttesttesttesttesttesttesttesttesttest",
    ]);

    expect(args.txid).toBe(txid);
    expect(args.amountSats).toBe(25000n);
    expect(args.opReturn).toHaveLength(73);
    expect(args.depositVout).toBe(2);
  });

  test("rejects malformed inputs before side effects", () => {
    expect(() => parseRelayArgs(["--txid", "bad"])).toThrow("--txid");
    expect(() => parseRelayArgs(["--txid", txid, "--amount-sats", "0", "--op-return", opReturn])).toThrow("--amount-sats");
    expect(() => parseRelayArgs(["--txid", txid, "--amount-sats", "1", "--op-return", "aa"])).toThrow("--op-return");
  });
});
