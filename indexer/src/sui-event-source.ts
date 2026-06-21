import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import type { SuiEvent } from "@mysten/sui/jsonRpc";
import type {
  NormalizedSuiUtxopiaEvent,
  SuiEventCursor,
  SuiEventSource,
  SuiIndexerConfig,
  SuiUtxopiaEventType,
} from "./types";

const KNOWN_EVENT_TYPES = new Set<SuiUtxopiaEventType>([
  "PoolCreated",
  "PoolPaused",
  "BtcDepositVerified",
  "CommitmentInserted",
  "MerkleRootUpdated",
  "NullifierSpent",
  "RedemptionRequested",
  "RedemptionCompleted",
  "IkaSigningApproved",
  "VerifyingKeyRegistered",
  "JoinSplitVerified",
  "StealthAnnounced",
]);

export class SuiUtxopiaEventSource implements SuiEventSource {
  private readonly client: SuiJsonRpcClient;

  constructor(private readonly config: SuiIndexerConfig) {
    this.client = new SuiJsonRpcClient({ url: config.rpcUrl });
  }

  /** Move event types keep the ORIGINAL defining package across upgrades. */
  private get eventsPackage(): string {
    return this.config.eventsPackageId ?? this.config.packageId;
  }

  async poll(cursor?: SuiEventCursor): Promise<{
    events: NormalizedSuiUtxopiaEvent[];
    nextCursor?: SuiEventCursor;
    hasNextPage: boolean;
  }> {
    const page = await this.client.queryEvents({
      query: {
        MoveEventModule: {
          package: this.eventsPackage,
          module: "events",
        },
      },
      cursor: cursor
        ? {
            txDigest: cursor.transactionDigest,
            eventSeq: cursor.eventSequence,
          }
        : null,
      limit: this.config.pageLimit ?? 50,
      order: "ascending",
    });

    return {
      events: page.data.map((event) => this.normalize(event)).filter((event) => event !== null),
      nextCursor: page.nextCursor
        ? {
            transactionDigest: page.nextCursor.txDigest,
            eventSequence: page.nextCursor.eventSeq,
          }
        : undefined,
      hasNextPage: page.hasNextPage,
    };
  }

  private normalize(event: SuiEvent): NormalizedSuiUtxopiaEvent | null {
    const eventType = event.type.split("::").at(-1);
    if (!eventType || !KNOWN_EVENT_TYPES.has(eventType as SuiUtxopiaEventType)) {
      return null;
    }

    return {
      type: eventType as SuiUtxopiaEventType,
      packageId: event.packageId,
      poolObjectId: this.config.poolObjectId,
      cursor: {
        transactionDigest: event.id.txDigest,
        eventSequence: event.id.eventSeq,
      },
      timestampMs: event.timestampMs ?? undefined,
      payload: this.payload(event.parsedJson),
    };
  }

  private payload(parsedJson: unknown): Record<string, unknown> {
    if (parsedJson && typeof parsedJson === "object" && !Array.isArray(parsedJson)) {
      return parsedJson as Record<string, unknown>;
    }

    return { value: parsedJson };
  }
}
