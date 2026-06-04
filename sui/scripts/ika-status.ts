#!/usr/bin/env bun
import { readState, writeState } from "./shared";
import { UTXOpiaSuiIkaAdapter } from "../../../packages/sdk-sui/src/ika";
import { activeSuiAddress } from "./signing";

const state = readState();
const ikaState = state.ikaSui ?? {};
const relayerAddress = state.relayer?.address ?? activeSuiAddress();
const adapter = new UTXOpiaSuiIkaAdapter({
  rpcUrl: process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443",
  network: (ikaState.network ?? "testnet") as "testnet" | "mainnet",
  dWalletId: ikaState.dWalletId,
  dWalletCapObjectId: ikaState.dWalletCapObjectId,
  networkEncryptionKeyId: ikaState.networkEncryptionKeyId,
  ikaCoinObjectId: ikaState.ikaCoinObjectId,
  suiCoinObjectId: ikaState.suiCoinObjectId,
});

const client = adapter.createClient();
await client.initialize();
const latestEncryptionKey = await client.getLatestNetworkEncryptionKey();
const caps = await client.getOwnedDWalletCaps(relayerAddress, undefined, 10);

state.ikaSui = {
  ...ikaState,
  network: ikaState.network ?? "testnet",
  packages: adapter.ikaConfig.packages,
  objects: adapter.ikaConfig.objects,
  networkEncryptionKeyId: ikaState.networkEncryptionKeyId || latestEncryptionKey.id,
};
writeState(state);

console.log(JSON.stringify({
  network: state.ikaSui.network,
  relayerAddress,
  latestEncryptionKey,
  ownedDWalletCaps: caps.dWalletCaps,
  hasNextPage: caps.hasNextPage,
  note: "Updated chains/sui/sui-poc-state.json with Ika Sui package/object config and latest networkEncryptionKeyId.",
}, null, 2));
