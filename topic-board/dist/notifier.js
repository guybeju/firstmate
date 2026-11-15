// Tells firstmate when a topic becomes dispatchable: it left the "later" queue
// or was reopened, and then stayed put for the delay. Dragging it back cancels;
// moving it again restarts the wait. The wait lives in memory only.
import { QUEUES } from "./topics.js";
const BATCH_WINDOW_MS = 1000;
/** "<queue>:<index>" of a topic that firstmate may dispatch from, or null. */
function dispatchableSpot(state, id) {
    for (const queue of QUEUES) {
        const index = state.doc.queues[queue].indexOf(id);
        if (index !== -1)
            return queue === "later" ? null : `${queue}:${index}`;
    }
    return null;
}
export class DispatchNotifier {
    delayMs;
    notify;
    pending = new Map();
    timer = null;
    constructor(delayMs, notify) {
        this.delayMs = delayMs;
        this.notify = notify;
    }
    /** Call after every topic change with the topics the change made dispatchable. */
    observe(before, after, becameDispatchable) {
        const due = Date.now() + this.delayMs;
        for (const id of [...this.pending.keys()]) {
            const spot = dispatchableSpot(after, id);
            if (spot === null)
                this.pending.delete(id);
            else if (spot !== dispatchableSpot(before, id))
                this.pending.set(id, due);
        }
        for (const id of becameDispatchable)
            this.pending.set(id, due);
        this.schedule();
    }
    stop() {
        if (this.timer !== null)
            clearTimeout(this.timer);
        this.timer = null;
    }
    schedule() {
        this.stop();
        if (this.pending.size === 0)
            return;
        const earliest = Math.min(...this.pending.values());
        this.timer = setTimeout(() => this.fire(), Math.max(0, earliest - Date.now()));
    }
    /** Sends one notice for every topic due now or within the batch window. */
    fire() {
        const cutoff = Date.now() + BATCH_WINDOW_MS;
        const ready = [...this.pending].filter(([, dueAt]) => dueAt <= cutoff).map(([id]) => id);
        for (const id of ready)
            this.pending.delete(id);
        if (ready.length > 0)
            this.notify(ready);
        this.schedule();
    }
}
