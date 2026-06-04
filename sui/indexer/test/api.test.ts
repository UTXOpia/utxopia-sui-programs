import { expect, test } from "bun:test";
import { createSuiIndexerApi } from "../src/api";
import { InMemorySuiIndexerStore } from "../src/storage";

test("serves health, state, and events", async () => {
  const store = new InMemorySuiIndexerStore();
  await store.saveEvents([
    {
      type: "PoolCreated",
      packageId: "0x1",
      poolObjectId: "0x2",
      cursor: { transactionDigest: "a", eventSequence: "0" },
      payload: {},
    },
  ]);

  const api = createSuiIndexerApi({ packageId: "0x1" }, store);

  const health = await api(new Request("http://local/health"));
  expect(health.status).toBe(200);
  expect(await health.json()).toEqual({ ok: true, packageId: "0x1" });

  const events = await api(new Request("http://local/events"));
  expect(await events.json()).toHaveLength(1);

  const missing = await api(new Request("http://local/missing"));
  expect(missing.status).toBe(404);
});

