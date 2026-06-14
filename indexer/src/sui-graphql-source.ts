//! Sui GraphQL event source (PLAN.md Phase 1 "native" option).
//!
//! One GraphQL request returns events + their tx digest + on-chain timestamp, filtered
//! server-side by the emitting module — far fewer round-trips than JSON-RPC `queryEvents`
//! pagination. Implements the same `SuiEventSource` interface as the JSON-RPC source, so
//! storage/projections/API are unchanged; pick it with UTXOPIA_SUI_INDEXER_SOURCE=graphql.
//!
//! Cursor model: we carry the GraphQL page `endCursor` in `SuiEventCursor.checkpoint`
//! (the opaque resume token), and use each event edge's opaque `cursor` as `eventSequence`
//! so the (txDigest, eventSequence) storage key stays unique and idempotent.
//!
//! NOTE: validate field selection against the deployed GraphQL endpoint's schema version
//! before making this the default; JSON-RPC remains the safe default source.

import type {
  NormalizedSuiUtxopiaEvent,
  SuiEventCursor,
  SuiEventSource,
  SuiIndexerConfig,
  SuiUtxopiaEventType,
} from "./types";

const KNOWN_EVENT_TYPES = new Set<SuiUtxopiaEventType>([
  "PoolCreated", "PoolPaused", "BtcDepositVerified", "CommitmentInserted",
  "MerkleRootUpdated", "NullifierSpent", "RedemptionRequested", "RedemptionCompleted",
  "IkaSigningApproved", "VerifyingKeyRegistered", "JoinSplitVerified",
]);

const EVENTS_QUERY = `
  query Events($filter: EventFilter, $after: String, $first: Int) {
    events(filter: $filter, after: $after, first: $first) {
      pageInfo { hasNextPage endCursor }
      edges {
        cursor
        node {
          timestamp
          transactionBlock { digest }
          contents { type { repr } json }
        }
      }
    }
  }
`;

interface GraphQLEventEdge {
  cursor: string;
  node: {
    timestamp?: string | null;
    transactionBlock?: { digest?: string | null } | null;
    contents?: { type?: { repr?: string | null } | null; json?: unknown } | null;
  };
}

export class SuiGraphQLEventSource implements SuiEventSource {
  private readonly url: string;

  constructor(private readonly config: SuiIndexerConfig) {
    if (!config.graphqlUrl) throw new Error("graphqlUrl is required for SuiGraphQLEventSource");
    this.url = config.graphqlUrl;
  }

  private get eventsPackage(): string {
    return this.config.eventsPackageId ?? this.config.packageId;
  }

  async poll(cursor?: SuiEventCursor): Promise<{
    events: NormalizedSuiUtxopiaEvent[];
    nextCursor?: SuiEventCursor;
    hasNextPage: boolean;
  }> {
    const variables = {
      filter: { emittingModule: `${this.eventsPackage}::events` },
      after: cursor?.checkpoint ?? null,
      first: this.config.pageLimit ?? 50,
    };

    const res = await fetch(this.url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: EVENTS_QUERY, variables }),
    });
    if (!res.ok) throw new Error(`Sui GraphQL ${res.status}: ${await res.text()}`);
    const body = (await res.json()) as {
      data?: { events?: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; edges: GraphQLEventEdge[] } };
      errors?: unknown;
    };
    if (body.errors) throw new Error(`Sui GraphQL errors: ${JSON.stringify(body.errors)}`);
    const conn = body.data?.events;
    if (!conn) return { events: [], hasNextPage: false };

    const events = conn.edges
      .map((edge) => this.normalize(edge))
      .filter((e): e is NormalizedSuiUtxopiaEvent => e !== null);

    const lastEdge = conn.edges.at(-1);
    const nextCursor: SuiEventCursor | undefined = conn.pageInfo.endCursor
      ? {
          checkpoint: conn.pageInfo.endCursor,
          transactionDigest: lastEdge?.node.transactionBlock?.digest ?? "",
          eventSequence: lastEdge?.cursor ?? conn.pageInfo.endCursor,
        }
      : undefined;

    return { events, nextCursor, hasNextPage: conn.pageInfo.hasNextPage };
  }

  private normalize(edge: GraphQLEventEdge): NormalizedSuiUtxopiaEvent | null {
    const repr = edge.node.contents?.type?.repr ?? "";
    const eventType = repr.split("::").at(-1);
    if (!eventType || !KNOWN_EVENT_TYPES.has(eventType as SuiUtxopiaEventType)) return null;
    const txDigest = edge.node.transactionBlock?.digest;
    if (!txDigest) return null;

    const ts = edge.node.timestamp ? Date.parse(edge.node.timestamp) : NaN;
    const json = edge.node.contents?.json;

    return {
      type: eventType as SuiUtxopiaEventType,
      packageId: this.config.packageId,
      poolObjectId: this.config.poolObjectId,
      cursor: {
        transactionDigest: txDigest,
        // Opaque per-event GraphQL cursor → stable, unique storage key component.
        eventSequence: edge.cursor,
      },
      timestampMs: Number.isFinite(ts) ? String(ts) : undefined,
      payload: json && typeof json === "object" && !Array.isArray(json)
        ? (json as Record<string, unknown>)
        : { value: json },
    };
  }
}
