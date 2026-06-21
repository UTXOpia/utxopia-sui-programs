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
  | "JoinSplitVerified"
  | "StealthAnnounced";

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
  /** On-chain timestamp (ms since epoch) of the emitting transaction, when available. */
  timestampMs?: string;
  payload: Record<string, unknown>;
}

/**
 * Pluggable event ingestion source. Implementations: JSON-RPC `queryEvents`
 * (`SuiUtxopiaEventSource`), Sui GraphQL (`SuiGraphQLEventSource`), and later a
 * checkpoint-stream source — all behind this one interface so storage/projections/API
 * never change when the source is swapped (PLAN.md Phase 1/3).
 */
export interface SuiEventSource {
  poll(cursor?: SuiEventCursor): Promise<{
    events: NormalizedSuiUtxopiaEvent[];
    nextCursor?: SuiEventCursor;
    hasNextPage: boolean;
  }>;
}

export interface SuiIndexerState {
  packageId: string;
  lastCursor?: SuiEventCursor;
}

export interface SuiIndexerConfig {
  rpcUrl: string;
  packageId: string;
  poolObjectId: string;
  /**
   * Defining package id of the `events` module. Move event types keep their ORIGINAL
   * package id across upgrades, so filtering must use this (not the latest packageId)
   * or an upgraded deployment yields zero events. Defaults to packageId.
   */
  eventsPackageId?: string;
  /** Sui GraphQL endpoint (used by SuiGraphQLEventSource). */
  graphqlUrl?: string;
  pageLimit?: number;
}
