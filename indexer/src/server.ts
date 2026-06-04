import { createSuiIndexerApi } from "./api";
import { InMemorySuiIndexerStore, SqliteSuiIndexerStore } from "./storage";
import { SuiUtxopiaEventSource } from "./sui-event-source";
import { SuiUtxopiaIndexerService } from "./service";

const packageId = process.env.UTXOPIA_SUI_PACKAGE_ID;
const poolObjectId = process.env.UTXOPIA_SUI_POOL_OBJECT_ID;
const rpcUrl = process.env.UTXOPIA_SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443";
const port = Number.parseInt(process.env.PORT ?? "8787", 10);
const dbPath = process.env.UTXOPIA_SUI_INDEXER_DB;
const pollMs = Number.parseInt(process.env.UTXOPIA_SUI_INDEXER_POLL_MS ?? "5000", 10);

if (!packageId) {
  throw new Error("UTXOPIA_SUI_PACKAGE_ID is required");
}
if (!poolObjectId) {
  throw new Error("UTXOPIA_SUI_POOL_OBJECT_ID is required");
}

const store = dbPath
  ? new SqliteSuiIndexerStore(dbPath)
  : new InMemorySuiIndexerStore();
const source = new SuiUtxopiaEventSource({
  rpcUrl,
  packageId,
  poolObjectId,
});
const service = new SuiUtxopiaIndexerService(packageId, source, store);
const fetch = createSuiIndexerApi({ packageId }, store);

let syncing = false;
async function sync() {
  if (syncing) return;
  syncing = true;
  try {
    await service.syncOnce();
  } catch (error) {
    console.error("[sui-indexer] sync failed", error);
  } finally {
    syncing = false;
  }
}

await sync();
setInterval(sync, pollMs).unref?.();

Bun.serve({
  port,
  fetch,
});

console.log(`UTXOpia Sui indexer API listening on http://127.0.0.1:${port}`);
console.log(`Sui indexer source: ${rpcUrl} package=${packageId} db=${dbPath ?? "memory"}`);
