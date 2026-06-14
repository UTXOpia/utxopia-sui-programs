// Minimal self-contained BIP-350 bech32m encoder for deriving a P2TR (witness v1)
// address from an x-only public key. No external deps — sui-programs only ships
// @mysten/sui, and the existing addressToScriptPubKey helper goes the wrong way
// (it shells into a regtest bitcoind). Kept here so config export can DERIVE the
// pool address from the bound dWallet key instead of storing it (see
// docs/config-centralization-plan.md).

const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const BECH32M_CONST = 0x2bc830a3;

function polymod(values: number[]): number {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) chk ^= (b >> i) & 1 ? GEN[i] : 0;
  }
  return chk;
}

function hrpExpand(hrp: string): number[] {
  const out: number[] = [];
  for (const c of hrp) out.push(c.charCodeAt(0) >> 5);
  out.push(0);
  for (const c of hrp) out.push(c.charCodeAt(0) & 31);
  return out;
}

function createChecksum(hrp: string, data: number[]): number[] {
  const values = hrpExpand(hrp).concat(data, [0, 0, 0, 0, 0, 0]);
  const pm = polymod(values) ^ BECH32M_CONST;
  return [0, 1, 2, 3, 4, 5].map((i) => (pm >> (5 * (5 - i))) & 31);
}

function convertBits(data: Uint8Array, from: number, to: number, pad: boolean): number[] {
  let acc = 0;
  let bits = 0;
  const ret: number[] = [];
  const maxv = (1 << to) - 1;
  for (const b of data) {
    acc = (acc << from) | b;
    bits += from;
    while (bits >= to) {
      bits -= to;
      ret.push((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) ret.push((acc << (to - bits)) & maxv);
  return ret;
}

/** Bitcoin network name (as used in web networks.json) -> bech32 HRP. */
export function hrpForNetwork(network: string): string {
  switch (network) {
    case "mainnet":
    case "bitcoin":
      return "bc";
    case "regtest":
      return "bcrt";
    case "testnet":
    case "testnet4":
    case "signet":
      return "tb";
    default:
      throw new Error(`unknown bitcoin network: ${network}`);
  }
}

function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length % 2 !== 0) throw new Error("odd-length hex");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** Encode a witness program as a bech32m segwit address (witver 1+ uses bech32m). */
export function encodeSegwit(hrp: string, witver: number, program: Uint8Array): string {
  const data = [witver].concat(convertBits(program, 8, 5, true));
  const combined = data.concat(createChecksum(hrp, data));
  return hrp + "1" + combined.map((d) => CHARSET[d]).join("");
}

/** Derive the P2TR (taproot, witness v1) address for an x-only pubkey on a network. */
export function p2trAddress(xonlyHex: string, network: string): string {
  const prog = hexToBytes(xonlyHex);
  if (prog.length !== 32) throw new Error(`x-only pubkey must be 32 bytes, got ${prog.length}`);
  return encodeSegwit(hrpForNetwork(network), 1, prog);
}
