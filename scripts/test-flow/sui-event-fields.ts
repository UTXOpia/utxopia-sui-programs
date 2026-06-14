export function bytesField(value: unknown): Uint8Array | null {
  if (!Array.isArray(value)) return null;
  const bytes = value.map((entry) => Number(entry));
  if (!bytes.every((entry) => Number.isInteger(entry) && entry >= 0 && entry <= 255)) return null;
  return Uint8Array.from(bytes);
}

export function bigintField(value: unknown): bigint | null {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isFinite(value)) return BigInt(Math.trunc(value));
  if (typeof value === "string" && /^\d+$/.test(value)) return BigInt(value);
  return null;
}

export function numberField(value: unknown): number | null {
  const valueBigint = bigintField(value);
  if (valueBigint == null || valueBigint > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(valueBigint);
}
