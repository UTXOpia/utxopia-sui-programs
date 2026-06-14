import { describe, expect, test } from "bun:test";
import { bigintField, bytesField, numberField } from "../test-flow/sui-event-fields";

describe("Sui event field parsing", () => {
  test("normalizes byte arrays", () => {
    expect(Array.from(bytesField([0, "1", 255]) ?? [])).toEqual([0, 1, 255]);
    expect(bytesField([256])).toBeNull();
    expect(bytesField("not-bytes")).toBeNull();
  });

  test("normalizes numeric fields", () => {
    expect(bigintField("42")).toBe(42n);
    expect(bigintField(42.9)).toBe(42n);
    expect(bigintField("4.2")).toBeNull();
    expect(numberField("42")).toBe(42);
    expect(numberField((BigInt(Number.MAX_SAFE_INTEGER) + 1n).toString())).toBeNull();
  });
});
