// Pure logic for projecting the canonical deploy state (utxopia-sui-state.json)
// onto a web networks.json entry. Phase 1 of docs/config-centralization-plan.md:
// deployment IDENTITY (package + object ids + bound dWallet) is generated from the
// deploy state, and the BTC pool address is DERIVED, not stored. Endpoints
// (rpcUrl/explorerUrl/Ika infra) are left untouched — different lifecycle.
import { p2trAddress } from "../lib/bech32m";

// Companions stored as shared-object refs { objectId, initialSharedVersion }.
const SHARED_REFS = [
  "pool",
  "commitmentTree",
  "btcDepositRegistry",
  "utxoSet",
  "nullifierRegistry",
  "redemptionQueue",
  "verifyingKeyRegistry",
  "tokenRegistry",
  "lightClient",
] as const;

function sharedRef(v: any) {
  return { objectId: v.objectId, initialSharedVersion: String(v.initialSharedVersion) };
}

/** Return a synced deep copy of one network entry; throws if it has no `sui` block. */
export function syncNetwork(net: any, state: any): any {
  const out = JSON.parse(JSON.stringify(net));
  const sui = out.sui;
  if (!sui) throw new Error("network entry has no `sui` block");

  sui.packageId = state.packageId;
  // Fresh package: events originate at the package itself.
  sui.eventsPackageId = state.packageId;

  for (const k of SHARED_REFS) {
    if (!state[k]) throw new Error(`deploy state missing ${k} — run init first`);
    sui[k] = sharedRef(state[k]);
  }
  sui.redemptionCap = {
    objectId: state.redemptionCap.objectId,
    version: String(state.redemptionCap.version),
    digest: state.redemptionCap.digest,
  };

  // Bound dWallet identity (the key the pool's btc_pool_script is bound to).
  sui.ika = sui.ika ?? {};
  sui.ika.dWalletId = state.ikaSui.dWalletId;
  sui.ika.dWalletCapObjectId = state.ikaSui.dWalletCapObjectId;

  // vk: refresh values for circuits the entry already lists; never change the set.
  if (sui.vk && state.vk) {
    for (const circuit of Object.keys(sui.vk)) {
      const sv = state.vk[circuit];
      if (!sv) continue;
      sui.vk[circuit] = {
        nInputs: sv.nInputs,
        nOutputs: sv.nOutputs,
        nPublic: sv.nPublic,
        vkHash: sv.vkHash,
        registerTxDigest: sv.registerTxDigest,
      };
    }
  }

  // Derived: pool address = P2TR(bound dWallet x-only key) for this BTC network.
  if (out.bitcoin?.network) {
    out.bitcoin.poolAddress = p2trAddress(state.ikaSui.dWalletXOnlyPubkey, out.bitcoin.network);
  }

  return out;
}

/**
 * Project `state` onto the given network keys of a parsed networks.json object.
 * Returns a new object; does not mutate the input. Unknown keys are reported.
 */
export function syncWebConfig(
  nets: Record<string, any>,
  state: any,
  keys: string[],
): { nets: Record<string, any>; synced: string[]; missing: string[] } {
  const out: Record<string, any> = JSON.parse(JSON.stringify(nets));
  const synced: string[] = [];
  const missing: string[] = [];
  for (const k of keys) {
    if (!out[k]?.sui) {
      missing.push(k);
      continue;
    }
    out[k] = syncNetwork(out[k], state);
    synced.push(k);
  }
  return { nets: out, synced, missing };
}

/** Network keys whose `sui.packageId` already tracks this deployment line, or all sui-* keys. */
export function defaultTargetKeys(nets: Record<string, any>): string[] {
  return Object.keys(nets).filter((k) => nets[k]?.chain === "sui" && nets[k]?.sui);
}
