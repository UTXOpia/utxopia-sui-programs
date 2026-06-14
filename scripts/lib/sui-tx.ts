import { Transaction } from "@mysten/sui/transactions";

export interface SharedObjectRefLike {
  objectId: string;
  initialSharedVersion: string | number;
}

export function shared(
  tx: Transaction,
  ref: SharedObjectRefLike,
  mutable: boolean,
) {
  return tx.sharedObjectRef({
    objectId: ref.objectId,
    initialSharedVersion: ref.initialSharedVersion,
    mutable,
  });
}

export function assertSuiSuccess(label: string, result: any) {
  const status = result.effects?.status;
  if (status?.status !== "success") {
    throw new Error(`${label} failed: ${JSON.stringify(status)}`);
  }
}
