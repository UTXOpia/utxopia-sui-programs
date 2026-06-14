import { describe, expect, test } from "bun:test";
import { concatBytes, hash256, reverseHexToBytes, toHex } from "../lib/bytes";
import {
  assertBitcoinMerkleRoot,
  assertBitcoinTxidMatches,
  buildBitcoinMerkleProof,
  findTxIndex,
} from "../test-flow/bitcoin-merkle";

const tx0 = "00".repeat(32);
const tx1 = "11".repeat(32);
const tx2 = "22".repeat(32);

describe("bitcoin merkle helpers", () => {
  test("builds a single-transaction proof", () => {
    const proof = buildBitcoinMerkleProof([tx0], 0);
    expect(proof.siblings).toHaveLength(0);
    expect(proof.pathBits).toBe(0n);
    expect(toHex(proof.root)).toBe(toHex(reverseHexToBytes(tx0)));
  });

  test("duplicates odd leaves and sets path bits for right-side siblings", () => {
    const proof = buildBitcoinMerkleProof([tx0, tx1, tx2], 2);
    const h01 = hash256(concatBytes(reverseHexToBytes(tx0), reverseHexToBytes(tx1)));
    const h22 = hash256(concatBytes(reverseHexToBytes(tx2), reverseHexToBytes(tx2)));
    const expectedRoot = hash256(concatBytes(h01, h22));

    expect(proof.siblings.map(toHex)).toEqual([
      toHex(reverseHexToBytes(tx2)),
      toHex(h01),
    ]);
    expect(proof.pathBits).toBe(0b10n);
    expect(toHex(proof.root)).toBe(toHex(expectedRoot));
    expect(() => assertBitcoinMerkleRoot(proof.root, expectedRoot)).not.toThrow();
  });

  test("finds tx index and reports missing tx clearly", () => {
    expect(findTxIndex({ hash: "block", txids: [tx0, tx1] }, tx1)).toBe(1);
    expect(() => findTxIndex({ hash: "block", txids: [tx0] }, tx1)).toThrow("was not found");
  });

  test("validates non-witness raw transaction txid serialization", () => {
    const rawTx = Uint8Array.from([1, 2, 3, 4]);
    const txid = toHex(Uint8Array.from(hash256(rawTx)).reverse());
    expect(() => assertBitcoinTxidMatches(rawTx, txid)).not.toThrow();
  });
});
