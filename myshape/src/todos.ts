// The hands-on items the board keeps for the captain (要你動手): what an
// aggregator puts on the page, where each item stands, and every way it leaves.
// Pure: each operation takes the store and returns the next one with the
// records and notices the change calls for; board-server.ts persists them.
import { GOAL_MAX, oneLine, resolveTopicId } from "./topics.js";
import type { TodoMark, TodoState, TopicState } from "./topics.js";

export type ItemState = "open" | TodoState;

/** One hands-on item, as `data/myshape/todos.json` stores it. */
export interface TodoItem {
  title: string;
  /** The topic it was put under (merges followed when shown); null only for an adopted item that had none. */
  topic: string | null;
  action: string;
  guidance: string;
  commands: string[];
  state: ItemState;
  /** Why the aggregator rejected the claim or no longer needs the item. */
  reason: string | null;
  /** When the state last changed. */
  at: string;
  /** The aggregator's name when the item was put on the board. */
  by: string;
  /** Opaque text the aggregator chose; the board only hands it back in notices. */
  ref: string;
  /** Only the captain's own press takes it down when it is no longer needed. */
  captain_closes: boolean;
  created_at: string;
}

export interface TodoStore {
  v: 1;
  items: Record<string, TodoItem>;
  /** Marks carried over from topics.json's `todos`, waiting for their item to be adopted. */
  marks: Record<string, TodoMark>;
}

export type CloseWords = "不做了" | "撤下";

export interface TodoEvent {
  kind: "todo.done" | "todo.dropped" | "todo.taken_down" | "todo.closed_elsewhere";
  topic: string | null;
  task: string;
  text: string;
}

export interface TodoNotice {
  event: "todo.claimed" | "todo.closed";
  id: string;
  title: string;
  ref: string;
  topic: string | null;
  text: string;
  by?: "captain" | "aggregator";
  words?: string;
}

export type TodoResult =
  | {
      ok: true;
      store: TodoStore;
      line: string;
      changed: boolean;
      events: TodoEvent[];
      notices: TodoNotice[];
    }
  | { ok: false; code: "refused" | "usage"; line: string };

/** What `todo add` asks for. */
export interface TodoInput {
  id: string;
  title: string;
  /** Required unless `adopt`; an adopted item may have none. */
  topic: string | null;
  action: string;
  guidance: string;
  commands: string[];
  ref: string;
  captainCloses: boolean;
  /** An item that existed before the board kept items: a waiting mark becomes its state. */
  adopt: boolean;
}

const ID_MAX = 128;
const REF_MAX = 128;
const ACTION_MAX = 1000;
const TEXT_MAX = 20_000;
const COMMANDS_MAX = 50;

export function emptyTodos(): TodoStore {
  return { v: 1, items: {}, marks: {} };
}

/** The id grammar topic ids and task ids share, at most 128 characters. */
export function isValidItemId(id: string): boolean {
  return (
    id.length <= ID_MAX && /^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(id) && !(id in Object.prototype)
  );
}

function refused(line: string): TodoResult {
  return { ok: false, code: "refused", line };
}

function usage(line: string): TodoResult {
  return { ok: false, code: "usage", line };
}

function unchanged(store: TodoStore, line: string): TodoResult {
  return { ok: true, store, line, changed: false, events: [], notices: [] };
}

function changed(
  store: TodoStore,
  line: string,
  events: TodoEvent[] = [],
  notices: TodoNotice[] = [],
): TodoResult {
  return { ok: true, store, line, changed: true, events, notices };
}

function itemOf(store: TodoStore, id: string): TodoItem | undefined {
  return Object.hasOwn(store.items, id) ? store.items[id] : undefined;
}

function notOpen(id: string): TodoResult {
  return refused(`${id} 不是看板上還開著的「要你動手」項目，沒有改任何東西。`);
}

/**
 * The topic an item goes under. A new item needs a live topic. An adopted
 * one keeps where today's page shows it: a merged id is followed, an archived
 * topic is kept, and an id the board does not know, or none, is no topic.
 */
function placeItem(topics: TopicState, input: TodoInput): { topic: string | null } | string {
  if (input.topic === null) return input.adopt ? { topic: null } : "需要 --topic <議題 id>。";
  const id = resolveTopicId(topics.doc, input.topic);
  if (topics.doc.topics[id] !== undefined) return { topic: id };
  if (!input.adopt) return `${input.topic} 不是看板上還開著的議題，沒有放上任何東西。`;
  return { topic: topics.archive.topics[id] === undefined ? null : id };
}

/** The input's problem as a usage line, or null when it is well formed. */
function inputProblem(input: TodoInput): string | null {
  if (!isValidItemId(input.id)) return `task id 格式不對：${input.id}`;
  if (oneLine(input.title, GOAL_MAX) === null) return `標題要是一行，最多 ${GOAL_MAX} 個字。`;
  if (oneLine(input.action, ACTION_MAX) === null) return "--do 要是一行。";
  if (input.guidance.length > TEXT_MAX) return "--note 太長。";
  if (input.commands.length > COMMANDS_MAX) return `--cmd 最多 ${COMMANDS_MAX} 個。`;
  if (input.commands.some((command) => command.trim() === "" || command.length > TEXT_MAX))
    return "--cmd 後面要有內容。";
  if (input.ref.length > REF_MAX || /[\n\r]/.test(input.ref))
    return "--ref 要是一行，最多 128 個字。";
  return null;
}

function sameText(item: TodoItem, input: TodoInput, topic: string | null): boolean {
  return (
    item.title === input.title.trim() &&
    item.topic === topic &&
    item.action === input.action.trim() &&
    item.guidance === input.guidance &&
    JSON.stringify(item.commands) === JSON.stringify(input.commands)
  );
}

function addedLine(id: string, topic: string | null): string {
  return `ok ${id} 已放上看板的「要你動手」（${topic === null ? "沒有議題" : `議題 ${topic}`}）`;
}

/**
 * Puts an item on the board, or rewrites it. A rewrite of different text
 * starts over at "open": what was said about the old text no longer holds.
 * Repeating the same text changes nothing; so does adopting an item already
 * on the board.
 */
export function addItem(
  store: TodoStore,
  topics: TopicState,
  input: TodoInput,
  now: string,
  by: string,
): TodoResult {
  const problem = inputProblem(input);
  if (problem !== null) return usage(problem);
  const placed = placeItem(topics, input);
  if (typeof placed === "string") return input.topic === null ? usage(placed) : refused(placed);
  const current = itemOf(store, input.id);
  const line = addedLine(input.id, placed.topic);
  if (current !== undefined && (input.adopt || sameText(current, input, placed.topic)))
    return unchanged(store, line);
  const next = structuredClone(store);
  const mark =
    input.adopt && Object.hasOwn(store.marks, input.id) ? store.marks[input.id] : undefined;
  delete next.marks[input.id];
  next.items[input.id] = {
    title: input.title.trim(),
    topic: placed.topic,
    action: input.action.trim(),
    guidance: input.guidance,
    commands: input.commands,
    state: mark?.state ?? "open",
    reason: mark?.reason ?? null,
    at: mark?.at ?? now,
    by,
    ref: input.ref !== "" ? input.ref : (current?.ref ?? ""),
    captain_closes: input.captainCloses || (current?.captain_closes ?? false),
    created_at: current?.created_at ?? now,
  };
  return changed(next, line);
}

function withState(
  store: TodoStore,
  id: string,
  state: ItemState,
  now: string,
  reason: string | null,
): TodoStore {
  const next = structuredClone(store);
  next.items[id] = { ...(next.items[id] as TodoItem), state, reason, at: now };
  return next;
}

function without(store: TodoStore, id: string): TodoStore {
  const next = structuredClone(store);
  delete next.items[id];
  return next;
}

function closing(
  item: TodoItem,
  id: string,
  text: string,
  by: "captain" | "aggregator",
  words: string,
): TodoNotice {
  return {
    event: "todo.closed",
    id,
    title: item.title,
    ref: item.ref,
    topic: item.topic,
    text,
    by,
    words,
  };
}

/** The captain's 做完了 on the page: the aggregator is told, and checks. */
export function claimItem(store: TodoStore, id: string, now: string, label: string): TodoResult {
  const item = itemOf(store, id);
  if (item === undefined) return notOpen(id);
  if (item.state === "obsolete") return refused(`${id} 已經被 ${label} 標成不再需要，請直接撤下。`);
  if (item.state === "claimed") return unchanged(store, `ok ${id} 本來就已記下做完了，等驗證`);
  const failed = `bin/myshape.sh todo failed ${id} --reason <一行>`;
  const text = `使用者在看板上：「${item.title}」做完了（${id}）。驗證後跑 bin/myshape.sh todo done ${id}；沒成功就跑 ${failed}`;
  const notice: TodoNotice = {
    event: "todo.claimed",
    id,
    title: item.title,
    ref: item.ref,
    topic: item.topic,
    text,
  };
  return changed(
    withState(store, id, "claimed", now, null),
    `ok ${id} 已記下做完了，等驗證`,
    [],
    [notice],
  );
}

/** The aggregator checked and it was not done: back in front of the captain with the reason. */
export function rejectItem(store: TodoStore, id: string, reason: string, now: string): TodoResult {
  const item = itemOf(store, id);
  if (item === undefined) return notOpen(id);
  const line = oneLine(reason, GOAL_MAX);
  if (line === null) return refused(`原因要是一行，最多 ${GOAL_MAX} 個字。`);
  if (item.state === "rejected" && item.reason === line)
    return unchanged(store, `ok ${id} 本來就已標成驗證沒過，回到要使用者動手`);
  return changed(
    withState(store, id, "rejected", now, line),
    `ok ${id} 已標成驗證沒過，回到要使用者動手`,
  );
}

/**
 * The aggregator no longer needs the item: it leaves the page at once, with
 * the reason in its topic's updates. An item only the captain may close waits
 * for the captain's 好，撤下 instead.
 */
export function obsoleteItem(
  store: TodoStore,
  id: string,
  reason: string,
  now: string,
  label: string,
): TodoResult {
  const item = itemOf(store, id);
  if (item === undefined) return notOpen(id);
  const line = oneLine(reason, GOAL_MAX);
  if (line === null) return refused(`原因要是一行，最多 ${GOAL_MAX} 個字。`);
  if (item.captain_closes) {
    if (item.state === "obsolete" && item.reason === line)
      return unchanged(store, `ok ${id} 本來就已標成不再需要，等使用者撤下`);
    return changed(
      withState(store, id, "obsolete", now, line),
      `ok ${id} 已標成不再需要，等使用者撤下`,
    );
  }
  const event: TodoEvent = {
    kind: "todo.taken_down",
    topic: item.topic,
    task: id,
    text: `「${item.title}」不再需要，${label} 撤下：${line}（${label} 用指令）`,
  };
  const notice = closing(
    item,
    id,
    `「${item.title}」已撤下：不再需要，${line}（${id}）`,
    "aggregator",
    "撤下",
  );
  return changed(without(store, id), `ok ${id} 已撤下（不再需要）`, [event], [notice]);
}

/** The aggregator checked that the captain did it: the item is closed. */
export function doneItem(store: TodoStore, id: string, label: string): TodoResult {
  const item = itemOf(store, id);
  if (item === undefined)
    return refused(`${id} 不是開著的「要你動手」項目，沒有關任何東西（已經關過的話不用再跑）。`);
  const event: TodoEvent = {
    kind: "todo.done",
    topic: item.topic,
    task: id,
    text: `「${item.title}」做完了，${label} 已驗證（${label} 用指令）`,
  };
  const notice = closing(
    item,
    id,
    `「${item.title}」已關：做完了，${label} 已驗證（${id}）`,
    "aggregator",
    "做完了",
  );
  return changed(without(store, id), `ok ${id} 已關（做完了，${label} 已驗證）`, [event], [notice]);
}

/**
 * The captain's 不做了, or 好，撤下 on an item the aggregator no longer needs:
 * the item leaves the page with the captain's words in its topic's updates.
 */
export function closeByCaptain(
  store: TodoStore,
  id: string,
  words: CloseWords,
  label: string,
): TodoResult {
  const item = itemOf(store, id);
  if (item === undefined) return notOpen(id);
  if (words === "撤下" && item.state !== "obsolete")
    return refused(`${id} 沒有被標成不再需要，不能撤下。`);
  if (words === "不做了" && (item.state === "obsolete" || item.state === "claimed"))
    return refused(`${id} 現在不能按不做了。`);
  const text =
    words === "撤下"
      ? `「${item.title}」不再需要（${label}：${item.reason ?? ""}），使用者按了好，撤下（在頁面上）`
      : `「${item.title}」使用者按了不做了（在頁面上）`;
  const event: TodoEvent = {
    kind: words === "撤下" ? "todo.taken_down" : "todo.dropped",
    topic: item.topic,
    task: id,
    text,
  };
  const notice = closing(
    item,
    id,
    `使用者在看板上：「${item.title}」${words}（${id}）`,
    "captain",
    words,
  );
  return changed(without(store, id), `ok ${id} 已拿掉（${words}）`, [event], [notice]);
}

/**
 * Ends an adoption pass. `open` is every item that is still an open hold on
 * the aggregator's side: a waiting mark of anything else is dropped, and an
 * adopted item (ref "hold") whose hold is gone leaves the page with a record
 * and no notice, since the hold was already closed elsewhere.
 */
export function adoptDone(store: TodoStore, open: string[], label: string): TodoResult {
  const still = new Set(open);
  const marks = Object.keys(store.marks).filter((id) => !still.has(id));
  const gone = Object.entries(store.items).filter(
    ([id, item]) => item.ref === "hold" && !still.has(id),
  );
  if (marks.length === 0 && gone.length === 0) return unchanged(store, "ok adopt-done 沒有要清的");
  const next = structuredClone(store);
  for (const id of marks) delete next.marks[id];
  const events: TodoEvent[] = gone.map(([id, item]) => {
    delete next.items[id];
    return {
      kind: "todo.closed_elsewhere",
      topic: item.topic,
      task: id,
      text: `「${item.title}」的 hold 已在別處關掉，從看板拿掉（${label} 用指令）`,
    };
  });
  return changed(
    next,
    `ok adopt-done 清掉 ${marks.length} 個等著的狀態，拿掉 ${gone.length} 個已在別處關掉的項目`,
    events,
  );
}

/**
 * What topics.json's `todos` keeps publishing: the mark of every item that is
 * not "open", plus every waiting mark, so a reader of that file (or an older
 * board after a rollback) still sees them.
 */
export function projectMarks(store: TodoStore): Record<string, TodoMark> {
  const marks: Record<string, TodoMark> = { ...store.marks };
  for (const [id, item] of Object.entries(store.items)) {
    if (item.state === "open") continue;
    marks[id] =
      item.reason === null
        ? { state: item.state, at: item.at }
        : { state: item.state, at: item.at, reason: item.reason };
  }
  return marks;
}

/** Where an item shows now: its topic with merges followed, or none. */
export function itemTopic(topics: TopicState, item: TodoItem): string | null {
  return item.topic === null ? null : resolveTopicId(topics.doc, item.topic);
}
