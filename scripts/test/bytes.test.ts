import { describe, expect, test } from "bun:test";
import {
  bytesToBigintBE,
  bytesToBigintLE,
  concatBytes,
  fieldToSuiBytes,
  hexToBytes,
  reverseHexToBytes,
  to0xHex,
  toHex,
} from "../lib/bytes";

describe("byte helpers", () => {
  test("normalizes hex and reverses Bitcoin display order", () => {
    expect(toHex(hexToBytes("0x000102ff"))).toBe("000102ff");
    expect(toHex(reverseHexToBytes("000102ff"))).toBe("ff020100");
  });

  test("encodes Sui field bytes little-endian", () => {
    expect(toHex(fieldToSuiBytes(0x0102n)).slice(0, 8)).toBe("02010000");
    expect(to0xHex(fieldToSuiBytes(0n))).toBe(`0x${"00".repeat(32)}`);
  });

  test("converts byte arrays to bigint with explicit endian", () => {
    const bytes = Uint8Array.from([0x01, 0x02, 0x03]);
    expect(bytesToBigintBE(bytes)).toBe(0x010203n);
    expect(bytesToBigintLE(bytes)).toBe(0x030201n);
  });

  test("concatenates array or variadic inputs", () => {
    const a = Uint8Array.from([1, 2]);
    const b = Uint8Array.from([3]);
    expect(Array.from(concatBytes(a, b))).toEqual([1, 2, 3]);
    expect(Array.from(concatBytes([a, b]))).toEqual([1, 2, 3]);
  });
});
