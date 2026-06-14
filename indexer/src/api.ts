import type { SuiIndexerStore } from "./storage";
import type { SqliteProjections } from "./projections";
import { buildExplorerStats, buildExplorerTransactions } from "./explorer-projection";

export interface SuiIndexerApiConfig {
  packageId: string;
  /** Pool BTC address surfaced in shield btcMeta (optional). */
  poolAddress?: string | null;
}

export function createSuiIndexerApi(
  config: SuiIndexerApiConfig,
  store: SuiIndexerStore,
  projections?: SqliteProjections,
) {
  return async function handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    // Lightweight access log (ops visibility + confirms who reads the indexer).
    if (url.pathname !== "/health") {
      console.log(`[api] ${req.method} ${url.pathname}${url.search}`);
    }

    if (url.pathname === "/health") {
      return json({ ok: true, packageId: config.packageId });
    }

    if (url.pathname === "/state") {
      return json(await store.getState(config.packageId) ?? { packageId: config.packageId });
    }

    if (url.pathname === "/events") {
      return json(await store.getEventsAfter(cursorFromUrl(url)));
    }

    // Normalized explorer API — what web/lib/sui/explorer.ts computes client-side today,
    // served from the DB so the web becomes a thin reader (events → DB → web).
    if (url.pathname === "/api/explorer/transactions") {
      const events = await store.getEventsAfter();
      return json(buildExplorerTransactions(events, { poolAddress: config.poolAddress ?? null }));
    }

    if (url.pathname === "/api/explorer/stats") {
      const events = await store.getEventsAfter();
      return json(buildExplorerStats(events));
    }

    // Projection-backed read API for the SDK (note scanning is client-side / Mode A).
    if (projections && url.pathname === "/pool-state") {
      return json(projections.getPoolState(config.packageId) ?? { packageId: config.packageId });
    }

    if (projections && url.pathname === "/commitments") {
      const fromLeaf = Number(url.searchParams.get("fromLeaf") ?? "0");
      return json(projections.getCommitments(config.packageId, Number.isFinite(fromLeaf) ? fromLeaf : 0));
    }

    if (projections && url.pathname === "/redemption") {
      const id = Number(url.searchParams.get("id") ?? "");
      if (!Number.isFinite(id)) return json({ error: "bad id" }, 400);
      return json(projections.getRedemption(config.packageId, id) ?? { error: "not found" }, 200);
    }

    return json({ error: "not found" }, 404);
  };
}

function cursorFromUrl(url: URL) {
  const transactionDigest = url.searchParams.get("txDigest");
  const eventSequence = url.searchParams.get("eventSeq");
  if (!transactionDigest || !eventSequence) {
    return undefined;
  }

  return { transactionDigest, eventSequence };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

