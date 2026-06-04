import type { SuiIndexerStore } from "./storage";
import type { SqliteProjections } from "./projections";

export interface SuiIndexerApiConfig {
  packageId: string;
}

export function createSuiIndexerApi(
  config: SuiIndexerApiConfig,
  store: SuiIndexerStore,
  projections?: SqliteProjections,
) {
  return async function handle(req: Request): Promise<Response> {
    const url = new URL(req.url);

    if (url.pathname === "/health") {
      return json({ ok: true, packageId: config.packageId });
    }

    if (url.pathname === "/state") {
      return json(await store.getState(config.packageId) ?? { packageId: config.packageId });
    }

    if (url.pathname === "/events") {
      return json(await store.getEventsAfter(cursorFromUrl(url)));
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

