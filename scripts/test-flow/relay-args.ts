export interface RelayArgs {
  txid: string;
  amountSats: bigint;
  opReturn: Uint8Array;
  depositAddress?: string;
  depositVout?: number;
}

export function parseRelayArgs(argv: string[]): RelayArgs {
  const map = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) continue;
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${key}`);
    }
    map.set(key.slice(2), value);
    i += 1;
  }

  const txid = map.get("txid") ?? "";
  if (!/^[0-9a-fA-F]{64}$/.test(txid)) {
    throw new Error("--txid must be a 32-byte hex Bitcoin txid");
  }

  const amountText = map.get("amount-sats") ?? "";
  if (!/^[1-9]\d*$/.test(amountText)) {
    throw new Error("--amount-sats must be a positive integer");
  }

  const opReturnHex = map.get("op-return") ?? "";
  if (!/^[0-9a-fA-F]{146}$/.test(opReturnHex)) {
    throw new Error("--op-return must be exactly 73 bytes of hex");
  }

  const depositVoutText = map.get("deposit-vout");
  const depositVout = depositVoutText == null ? undefined : Number(depositVoutText);
  if (depositVout != null && (!Number.isInteger(depositVout) || depositVout < 0)) {
    throw new Error("--deposit-vout must be a non-negative integer");
  }

  const depositAddress = map.get("deposit-address");
  if (depositAddress && !/^bcrt1[a-z0-9]{38,90}$/.test(depositAddress)) {
    throw new Error("--deposit-address must be a regtest bech32/bech32m address");
  }

  return {
    txid: txid.toLowerCase(),
    amountSats: BigInt(amountText),
    opReturn: Uint8Array.from(Buffer.from(opReturnHex, "hex")),
    depositAddress,
    depositVout,
  };
}
