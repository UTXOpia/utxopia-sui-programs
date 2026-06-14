import { createSuiIndexerApi } from "./api";
import { InMemorySuiIndexerStore, SqliteSuiIndexerStore } from "./storage";
import { SuiUtxopiaEventSource } from "./sui-event-source";
import { SuiGraphQLEventSource } from "./sui-graphql-source";
import { SqliteProjections } from "./projections";
import { SuiUtxopiaIndexerService } from "./service";
import type { SuiEventSource, SuiIndexerConfig } from "./types";

const packageId = process.env.UTXOPIA_SUI_PACKAGE_ID;
const poolObjectId = process.env.UTXOPIA_SUI_POOL_OBJECT_ID;
// Move event types keep their original defining package across upgrades — filter by it.
const eventsPackageId = process.env.UTXOPIA_SUI_EVENTS_PACKAGE_ID ?? packageId;
const poolAddress = process.env.UTXOPIA_SUI_POOL_BTC_ADDRESS ?? null;
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443";
const graphqlUrl = process.env.UTXOPIA_SUI_GRAPHQL_URL;
const sourceKind = (process.env.UTXOPIA_SUI_INDEXER_SOURCE ?? "jsonrpc").toLowerCase();
const port = Number.parseInt(process.env.PORT ?? "8787", 10);
const dbPath = process.env.UTXOPIA_SUI_INDEXER_DB;
const pollMs = Number.parseInt(process.env.UTXOPIA_SUI_INDEXER_POLL_MS ?? "5000", 10);

if (!packageId) {
  throw new Error("UTXOPIA_SUI_PACKAGE_ID is required");
}
if (!poolObjectId) {
  throw new Error("UTXOPIA_SUI_POOL_OBJECT_ID is required");
}

const sqliteStore = dbPath ? new SqliteSuiIndexerStore(dbPath) : null;
const store = sqliteStore ?? new InMemorySuiIndexerStore();
// Projections share the store's sqlite handle so events + derived state commit together.
const projections = sqliteStore ? new SqliteProjections(sqliteStore.database) : undefined;

const sourceConfig: SuiIndexerConfig = { rpcUrl, packageId, poolObjectId, eventsPackageId, graphqlUrl };
const source: SuiEventSource =
  sourceKind === "graphql"
    ? new SuiGraphQLEventSource(sourceConfig)
    : new SuiUtxopiaEventSource(sourceConfig);

const service = new SuiUtxopiaIndexerService(packageId, source, store, projections);
const fetch = createSuiIndexerApi({ packageId, poolAddress }, store, projections);

let syncing = false;
async function sync() {
  if (syncing) return;
  syncing = true;
  try {
    // Drain all pending pages each tick so we catch up fast after downtime.
    let total = 0;
    let n = await service.syncOnce();
    total += n;
    while (n > 0) {
      n = await service.syncOnce();
      total += n;
      if (total > 100_000) break; // safety valve
    }
  } catch (error) {
    console.error("[sui-indexer] sync failed", error);
  } finally {
    syncing = false;
  }
}

await sync();
setInterval(sync, pollMs).unref?.();

Bun.serve({ port, fetch });

console.log(`UTXOpia Sui indexer API listening on http://127.0.0.1:${port}`);
console.log(
  `Sui indexer source=${sourceKind} rpc=${rpcUrl}${graphqlUrl ? ` graphql=${graphqlUrl}` : ""} ` +
  `package=${packageId} events=${eventsPackageId} db=${dbPath ?? "memory"}`,
);
