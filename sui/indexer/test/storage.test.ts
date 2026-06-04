import { expect, test } from "bun:test";
import { InMemorySuiIndexerStore } from "../src/storage";

test("stores normalized events after a cursor", async () => {
  const store = new InMemorySuiIndexerStore();
  await store.saveEvents([
    {
      type: "PoolCreated",
      packageId: "0x1",
      poolObjectId: "0x2",
      cursor: { transactionDigest: "a", eventSequence: "0" },
      payload: {},
    },
    {
      type: "CommitmentInserted",
      packageId: "0x1",
      poolObjectId: "0x2",
      cursor: { transactionDigest: "b", eventSequence: "0" },
      payload: {},
    },
  ]);

  const events = await store.getEventsAfter({ transactionDigest: "a", eventSequence: "0" });

  expect(events).toHaveLength(1);
  expect(events[0].type).toBe("CommitmentInserted");
});

