import { Transaction } from "@mysten/sui/transactions";
import { readState, writeState, objectRefFromChange, requireState } from "./shared";
import { executeBuiltTransaction } from "./signing";

const state = readState();
const packageId = requireState(state.packageId, "packageId");
const pool = requireState(state.pool, "pool");
const adminCap = requireState(state.adminCap, "adminCap");
const xonly = state.ikaSui?.dWalletXOnlyPubkey;
if (!xonly || !/^[0-9a-fA-F]{64}$/.test(xonly)) throw new Error("dWallet x-only pubkey missing");
const script = Array.from(Buffer.concat([Buffer.from([0x51, 0x20]), Buffer.from(xonly, "hex")]));
console.log("binding pool btc_pool_script -> P2TR(", xonly, ")  scriptLen=", script.length);

const tx = new Transaction();
tx.moveCall({
  target: `${packageId}::pool::set_btc_pool_script`,
  arguments: [
    tx.object(adminCap.objectId),
    tx.sharedObjectRef({ objectId: pool.objectId, initialSharedVersion: pool.initialSharedVersion, mutable: true }),
    tx.pure.vector("u8", script),
  ],
});
const result = await executeBuiltTransaction(tx);
const st = result.effects?.status;
if (st?.status !== "success") throw new Error("set_btc_pool_script failed: " + JSON.stringify(st));
const adminChange = (result.objectChanges ?? []).find((c: any) => c.objectId === adminCap.objectId && (c.type === "mutated" || c.type === "created"));
state.adminCap = objectRefFromChange(adminChange) ?? state.adminCap;
writeState(state);
console.log(JSON.stringify({ digest: result.digest, status: st.status, btcPoolScript: "0x" + Buffer.from(script).toString("hex") }, null, 2));
