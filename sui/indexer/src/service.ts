import type { SuiUtxopiaEventSource } from "./sui-event-source";
import type { SuiIndexerStore } from "./storage";

export class SuiUtxopiaIndexerService {
  constructor(
    private readonly packageId: string,
    private readonly source: SuiUtxopiaEventSource,
    private readonly store: SuiIndexerStore,
  ) {}

  async syncOnce(): Promise<number> {
    const state = await this.store.getState(this.packageId);
    const page = await this.source.poll(state?.lastCursor);

    await this.store.saveEvents(page.events);
    if (page.nextCursor) {
      await this.store.saveState({
        packageId: this.packageId,
        lastCursor: page.nextCursor,
      });
    }

    return page.events.length;
  }
}

