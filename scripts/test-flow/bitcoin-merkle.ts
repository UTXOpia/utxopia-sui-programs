import { concatBytes, hash256, reverseHexToBytes, toHex } from "../lib/bytes";

export interface BitcoinMerkleProof {
  siblings: Uint8Array[];
  pathBits: bigint;
  root: Uint8Array;
}

export interface BitcoinBlockTxIndex {
  hash: string;
  txids: string[];
}

export function findTxIndex(block: BitcoinBlockTxIndex, txid: string): number {
  const index = block.txids.findIndex((candidate) => candidate === txid);
  if (index < 0) {
    throw new Error(`BTC transaction ${txid} was not found in block ${block.hash}`);
  }
  return index;
}

export function buildBitcoinMerkleProof(txids: string[], txIndex: number): BitcoinMerkleProof {
  if (txids.length === 0) {
    throw new Error("Cannot build a merkle proof for an empty transaction list");
  }
  if (!Number.isInteger(txIndex) || txIndex < 0 || txIndex >= txids.length) {
    throw new Error(`txIndex ${txIndex} is out of range for ${txids.length} transactions`);
  }

  let level = txids.map(reverseHexToBytes);
  let index = txIndex;
  let pathBits = 0n;
  const siblings: Uint8Array[] = [];

  while (level.length > 1) {
    const siblingIndex = index % 2 === 0
      ? Math.min(index + 1, level.length - 1)
      : index - 1;
    siblings.push(level[siblingIndex]);
    if (index % 2 === 1) {
      pathBits |= 1n << BigInt(siblings.length - 1);
    }

    const next: Uint8Array[] = [];
    for (let i = 0; i < level.length; i += 2) {
      const left = level[i];
      const right = level[i + 1] ?? left;
      next.push(hash256(concatBytes(left, right)));
    }
    level = next;
    index = Math.floor(index / 2);
  }

  return { siblings, pathBits, root: level[0] };
}

export function assertBitcoinMerkleRoot(actual: Uint8Array, expected: Uint8Array) {
  if (toHex(actual) !== toHex(expected)) {
    throw new Error(`Merkle proof root mismatch: got ${toHex(actual)}, expected ${toHex(expected)}`);
  }
}

export function assertBitcoinTxidMatches(rawTx: Uint8Array, txid: string) {
  const actual = toHex(hash256(rawTx));
  const expected = toHex(reverseHexToBytes(txid));
  if (actual !== expected) {
    throw new Error(`Bitcoin txid serialization hash mismatch: got ${actual}, expected ${expected}`);
  }
}
