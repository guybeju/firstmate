// Tells firstmate when a topic becomes dispatchable: it left the "later" queue
// or was reopened, and then stayed put for the delay. Dragging it back cancels;
// moving it again restarts the wait. The wait lives in memory only.
import { QUEUES } from "./topics.js";
import type { TopicState } from "./topics.js";

const BATCH_WINDOW_MS = 1000;

/** "<queue>:<index>" of a topic that firstmate may dispatch from, or null. */
function dispatchableSpot(state: TopicState, id: string): string | null {
  for (const queue of QUEUES) {
    const index = state.doc.queues[queue].indexOf(id);
    if (index !== -1) return queue === "later" ? null : `${queue}:${index}`;
  }
  return null;
}

export class DispatchNotifier {
  private readonly pending = new Map<string, number>();
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly delayMs: number,
    private readonly notify: (topicIds: string[]) => void,
  ) {}

  /** Call after every topic change with the topics the change made dispatchable. */
  observe(before: TopicState, after: TopicState, becameDispatchable: string[]): void {
    const due = Date.now() + this.delayMs;
    for (const id of [...this.pending.keys()]) {
      const spot = dispatchableSpot(after, id);
      if (spot === null) this.pending.delete(id);
      else if (spot !== dispatchableSpot(before, id)) this.pending.set(id, due);
    }
    for (const id of becameDispatchable) this.pending.set(id, due);
    this.schedule();
  }

  stop(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(): void {
    this.stop();
    if (this.pending.size === 0) return;
    const earliest = Math.min(...this.pending.values());
    this.timer = setTimeout(() => this.fire(), Math.max(0, earliest - Date.now()));
  }

  /** Sends one notice for every topic due now or within the batch window. */
  private fire(): void {
    const cutoff = Date.now() + BATCH_WINDOW_MS;
    const ready = [...this.pending].filter(([, dueAt]) => dueAt <= cutoff).map(([id]) => id);
    for (const id of ready) this.pending.delete(id);
    if (ready.length > 0) this.notify(ready);
    this.schedule();
  }
}
