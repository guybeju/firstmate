// The board's system records: what every change writes to events.jsonl, and
// who the board can attest made it. A change is a result that carries at
// least one record (topics.ts, todos.ts); store.ts commitChange is the only
// code that stamps and saves them.

/** Every kind of system record the board writes. */
export const RECORD_KINDS = [
  "topic.created",
  "topic.confirmed",
  "topic.merged",
  "topic.split",
  "topic.close_proposed",
  "topic.kept",
  "topic.archived",
  "topic.reopened",
  "topic.moved",
  "topic.renamed",
  "topic.goal_changed",
  "todo.opened",
  "todo.rewritten",
  "todo.adopted",
  "todo.claimed",
  "todo.rejected",
  "todo.obsolete",
  "todo.done",
  "todo.dropped",
  "todo.taken_down",
  "todo.forgotten",
  "todo.settled",
  "todo.marks_carried",
  "hold.answered",
  "hold.closed",
  "agent.tagged",
] as const;
export type RecordKind = (typeof RECORD_KINDS)[number];

/**
 * A record before it is saved. `text` is the line the page shows, with its
 * actor suffix when it has one; `item` names a hands-on item; `home` and
 * `task` name an agent; `outcome` and `reason` say how something ended or why.
 */
export interface Draft {
  kind: RecordKind;
  topic: string | null;
  home?: string | null;
  task?: string | null;
  item?: string;
  outcome?: string;
  reason?: string;
  text: string;
}

/** What a change must carry: one record at least. */
export type Records = readonly [Draft, ...Draft[]];

/**
 * Who made a change, as far as the board can attest: the holder of the page's
 * token (the captain), a local process through the socket (the aggregator,
 * by its label at the time), or the board itself at startup.
 */
export interface Actor {
  by: "captain" | "aggregator" | "board";
  label: string;
}

/** A saved record, as one `src: "board"` line of events.jsonl. */
export interface StoredRecord {
  src: "board";
  rid: string;
  ts: number;
  kind: string;
  topic: string | null;
  home: string | null;
  task: string | null;
  text: string;
  item?: string;
  by: string;
  label: string;
  outcome?: string;
  reason?: string;
}

/** Turns a draft into the record saved for it. */
export function stampRecord(draft: Draft, actor: Actor, rid: string, ts: number): StoredRecord {
  return {
    src: "board",
    rid,
    ts,
    kind: draft.kind,
    topic: draft.topic,
    home: draft.home ?? null,
    task: draft.task ?? null,
    ...(draft.item === undefined ? {} : { item: draft.item }),
    by: actor.by,
    label: actor.label,
    ...(draft.outcome === undefined ? {} : { outcome: draft.outcome }),
    ...(draft.reason === undefined ? {} : { reason: draft.reason }),
    text: draft.text,
  };
}

/** A whole state, read only: only topics.ts, todos.ts and store.ts build the next one. */
export type Frozen<T> = T extends readonly (infer U)[]
  ? readonly Frozen<U>[]
  : T extends object
    ? { readonly [K in keyof T]: Frozen<T[K]> }
    : T;
