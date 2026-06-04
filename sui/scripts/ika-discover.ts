#!/usr/bin/env bun
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { readState, writeState } from "./shared";
import { activeSuiAddress } from "./signing";
import { UTXOpiaSuiIkaAdapter } from "@utxopia/sdk/sui";

const state = readState();
const ikaState = state.ikaSui ?? {};
const relayerAddress = process.env.UTXOPIA_SUI_RELAYER_ADDRESS ?? state.relayer?.address ?? activeSuiAddress();
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? state.rpcUrl ?? "https://fullnode.testnet.sui.io:443";
const adapter = new UTXOpiaSuiIkaAdapter({
  rpcUrl,
  network: (ikaState.network ?? "testnet") as "testnet" | "mainnet",
});
const client = adapter.createClient();
await client.initialize();

const sui = new SuiJsonRpcClient({ url: rpcUrl, network: "testnet" });
const ikaCoinType = `${adapter.ikaConfig.packages.ikaPackage}::ika::IKA`;
const [suiCoins, ikaCoins, caps, latestEncryptionKey] = await Promise.all([
  sui.getCoins({ owner: relayerAddress, coinType: "0x2::sui::SUI", limit: 20 }),
  sui.getCoins({ owner: relayerAddress, coinType: ikaCoinType, limit: 20 }),
  client.getOwnedDWalletCaps(relayerAddress, undefined, 20),
  client.getLatestNetworkEncryptionKey(),
]);
const importedCaps = await sui.getOwnedObjects({
  owner: relayerAddress,
  filter: {
    StructType: `${adapter.ikaConfig.packages.ikaDwallet2pcMpcOriginalPackage}::coordinator_inner::ImportedKeyDWalletCap`,
  },
  options: {
    showContent: true,
    showType: true,
  },
  limit: 20,
});

const firstSuiCoin = suiCoins.data[0]?.coinObjectId ?? "";
const firstIkaCoin = ikaCoins.data[0]?.coinObjectId ?? "";
const firstCap = caps.dWalletCaps[0] as any;
const firstImportedCap = importedCaps.data[0] as any;
const firstDWalletCapObjectId =
  firstCap?.id?.id ??
  firstCap?.id ??
  firstImportedCap?.data?.objectId ??
  "";
const firstDWalletId =
  firstCap?.dwallet_id ??
  firstCap?.dwalletId ??
  firstCap?.dwallet?.id?.id ??
  firstImportedCap?.data?.content?.fields?.dwallet_id ??
  "";

if (process.env.UTXOPIA_SUI_IKA_AUTO_SELECT === "1") {
  state.ikaSui = {
    ...ikaState,
    network: ikaState.network ?? "testnet",
    packages: adapter.ikaConfig.packages,
    objects: adapter.ikaConfig.objects,
    networkEncryptionKeyId: ikaState.networkEncryptionKeyId || latestEncryptionKey.id,
    dWalletId: ikaState.dWalletId || firstDWalletId,
    dWalletCapObjectId: ikaState.dWalletCapObjectId || firstDWalletCapObjectId,
    ikaCoinObjectId: ikaState.ikaCoinObjectId || firstIkaCoin,
    suiCoinObjectId: ikaState.suiCoinObjectId || firstSuiCoin,
  };
  writeState(state);
}

console.log(JSON.stringify({
  relayerAddress,
  ikaCoinType,
  latestEncryptionKey,
  suggestedEnv: {
    UTXOPIA_SUI_IKA_NETWORK_ENCRYPTION_KEY_ID: latestEncryptionKey.id,
    UTXOPIA_SUI_IKA_DWALLET_ID: firstDWalletId,
    UTXOPIA_SUI_IKA_DWALLET_CAP_ID: firstDWalletCapObjectId,
    UTXOPIA_SUI_IKA_COIN_ID: firstIkaCoin,
    UTXOPIA_SUI_IKA_SUI_COIN_ID: firstSuiCoin,
  },
  suiCoins: suiCoins.data.map((coin) => ({
    coinObjectId: coin.coinObjectId,
    balance: coin.balance,
  })),
  ikaCoins: ikaCoins.data.map((coin) => ({
    coinObjectId: coin.coinObjectId,
    balance: coin.balance,
  })),
  dWalletCaps: caps.dWalletCaps,
  importedKeyDWalletCaps: importedCaps.data.map((cap: any) => ({
    objectId: cap.data?.objectId,
    type: cap.data?.type,
    dWalletId: cap.data?.content?.fields?.dwallet_id,
  })),
  autoSelectApplied: process.env.UTXOPIA_SUI_IKA_AUTO_SELECT === "1",
}, null, 2));
