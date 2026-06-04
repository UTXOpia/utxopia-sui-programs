import type { SuiIndexerStore } from "./storage";

export interface SuiIndexerApiConfig {
  packageId: string;
}

export function createSuiIndexerApi(config: SuiIndexerApiConfig, store: SuiIndexerStore) {
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

