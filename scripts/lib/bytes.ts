import { createHash } from "node:crypto";

export function hexToBytes(hex: string): Uint8Array {
  const normalized = hex.startsWith("0x") ? hex.slice(2) : hex;
  return Uint8Array.from(Buffer.from(normalized, "hex"));
}

export function reverseHexToBytes(hex: string): Uint8Array {
  return Uint8Array.from(Buffer.from(hex, "hex").reverse());
}

export function toHex(bytes: Uint8Array | Buffer): string {
  return Buffer.from(bytes).toString("hex");
}

export function to0xHex(bytes: Uint8Array | Buffer): string {
  return `0x${toHex(bytes)}`;
}

export function fieldToSuiBytes(value: bigint): Uint8Array {
  const bytes = Buffer.alloc(32);
  let n = value;
  for (let i = 0; i < 32; i += 1) {
    bytes[i] = Number(n & 0xffn);
    n >>= 8n;
  }
  return bytes;
}

export function bytesToBigintBE(bytes: Uint8Array): bigint {
  let result = 0n;
  for (const byte of bytes) {
    result = (result << 8n) | BigInt(byte);
  }
  return result;
}

export function bytesToBigintLE(bytes: Uint8Array): bigint {
  let result = 0n;
  for (let i = bytes.length - 1; i >= 0; i -= 1) {
    result = (result << 8n) | BigInt(bytes[i]);
  }
  return result;
}

export function concatBytes(parts: Uint8Array[]): Uint8Array;
export function concatBytes(...parts: Uint8Array[]): Uint8Array;
export function concatBytes(...input: [Uint8Array[]] | Uint8Array[]): Uint8Array {
  const parts = Array.isArray(input[0]) ? input[0] as Uint8Array[] : input as Uint8Array[];
  return Uint8Array.from(Buffer.concat(parts.map((part) => Buffer.from(part))));
}

export function hash256(bytes: Uint8Array): Uint8Array {
  const first = createHash("sha256").update(bytes).digest();
  return Uint8Array.from(createHash("sha256").update(first).digest());
}
