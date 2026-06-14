import type { SuiIndexerStore } from "./storage";
import type { NormalizedSuiUtxopiaEvent, SuiEventSource } from "./types";

/** Anything that can fold a batch of events into derived state (e.g. SqliteProjections). */
export interface EventProjector {
  apply(events: NormalizedSuiUtxopiaEvent[]): void;
}

export class SuiUtxopiaIndexerService {
  constructor(
    private readonly packageId: string,
    private readonly source: SuiEventSource,
    private readonly store: SuiIndexerStore,
    private readonly projections?: EventProjector,
  ) {}

  async syncOnce(): Promise<number> {
    const state = await this.store.getState(this.packageId);
    const page = await this.source.poll(state?.lastCursor);

    // Persist raw events first, then fold projections, then advance the cursor. Ordering
    // it this way means a crash mid-sync re-fetches the same page (events are insert-or-
    // ignore and projections are idempotent on the dense leaf prefix), never skips one.
    // NOTE (spec 06 E4): for full atomicity the store + projections should share one
    // sqlite handle so the three writes commit together — tracked follow-up.
    await this.store.saveEvents(page.events);
    if (this.projections) this.projections.apply(page.events);

    if (page.nextCursor) {
      await this.store.saveState({
        packageId: this.packageId,
        lastCursor: page.nextCursor,
      });
    }

    return page.events.length;
  }
}
