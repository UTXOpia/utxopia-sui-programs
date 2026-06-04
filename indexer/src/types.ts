export type SuiUtxopiaEventType =
  | "PoolCreated"
  | "PoolPaused"
  | "BtcDepositVerified"
  | "CommitmentInserted"
  | "MerkleRootUpdated"
  | "NullifierSpent"
  | "RedemptionRequested"
  | "RedemptionCompleted"
  | "IkaSigningApproved"
  | "VerifyingKeyRegistered"
  | "JoinSplitVerified";

export interface SuiEventCursor {
  checkpoint?: string;
  transactionDigest: string;
  eventSequence: string;
}

export interface NormalizedSuiUtxopiaEvent {
  type: SuiUtxopiaEventType;
  packageId: string;
  poolObjectId: string;
  cursor: SuiEventCursor;
  payload: Record<string, unknown>;
}

export interface SuiIndexerState {
  packageId: string;
  lastCursor?: SuiEventCursor;
}

export interface SuiIndexerConfig {
  rpcUrl: string;
  packageId: string;
  poolObjectId: string;
  pageLimit?: number;
}
