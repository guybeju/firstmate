// The topic model and every change the board can make to it. Pure: no I/O, no
// clock. Callers pass the current time and persist the returned state.

export const QUEUES = ["high", "normal", "later"] as const;
export type Queue = (typeof QUEUES)[number];

export interface CloseProposal {
  at: string;
  reason: string;
}

export interface Topic {
  name: string;
  goal: string;
  // Every topic is confirmed the moment it is created. The field stays in the
  // file so that older board code, which still reads it, keeps working.
  status: "confirmed";
  created_at: string;
  close_proposal?: CloseProposal;
}

export interface ArchivedTopic extends Topic {
  archived_at: string;
}

export const HISTORY_KINDS = [
  "merged",
  "renamed",
  "split",
  "archived",
  "reopened",
  "moved",
  "goal",
] as const;
export type HistoryKind = (typeof HISTORY_KINDS)[number];

/**
 * One change to a topic's identity, kept so an old name or id can be traced.
 * `topic` and `name` are the topic the change left behind; a merge also names
 * the topic that went away (`from`, `from_name`), a rename the old name, and
 * a split the topic it was split off from. `reason` is why, when someone said:
 * the line given with a merge or split, or the close proposal an archive
 * followed. `by` is where the change was made, the board page or a command.
 * A move records the queue and 1-based place it went to, a goal change the
 * new goal.
 */
export interface HistoryEntry {
  at: string;
  kind: HistoryKind;
  topic: string;
  name: string;
  from?: string;
  from_name?: string;
  reason?: string;
  by?: HistoryActor;
  queue?: Queue;
  position?: number;
  goal?: string;
}

export const HISTORY_ACTORS = ["page", "command"] as const;
export type HistoryActor = (typeof HISTORY_ACTORS)[number];

export const TODO_STATES = ["claimed", "rejected", "obsolete"] as const;
export type TodoState = (typeof TODO_STATES)[number];

/**
 * Where a hands-on item for the captain stands beyond "still to do": the
 * captain says it is done and firstmate has yet to check ("claimed"),
 * firstmate checked and it was not ("rejected"), or firstmate no longer needs
 * it ("obsolete"). Keyed by the main home's task id.
 */
export interface TodoMark {
  state: TodoState;
  at: string;
  reason?: string;
}

export interface TopicsDoc {
  v: 1;
  next_seq: number;
  queues: Record<Queue, string[]>;
  topics: Record<string, Topic>;
  merged: Record<string, string>;
  /** Oldest first. Files written before the history existed load with none. */
  history: HistoryEntry[];
  /** Files written before hands-on items existed load with none. */
  todos: Record<string, TodoMark>;
}

export interface ArchiveDoc {
  v: 1;
  topics: Record<string, ArchivedTopic>;
}

export interface TopicState {
  doc: TopicsDoc;
  archive: ArchiveDoc;
}

export type SystemEventKind =
  | "topic.created"
  | "topic.confirmed"
  | "topic.merged"
  | "topic.split"
  | "topic.close_proposed"
  | "topic.archived"
  | "topic.reopened"
  | "topic.moved"
  | "topic.renamed"
  | "topic.goal_changed";

export interface TopicEvent {
  kind: SystemEventKind;
  topic: string;
  text: string;
}

export type TopicResult =
  | {
      ok: true;
      state: TopicState;
      line: string;
      changed: boolean;
      events: TopicEvent[];
      // Ids of topics that just became dispatchable (left "later" or were reopened).
      dispatchable: string[];
    }
  | { ok: false; code: "refused"; line: string };

export const NAME_MAX = 80;
export const GOAL_MAX = 200;
const ID_MAX = 64;
export const QUEUE_LABEL: Record<Queue, string> = { high: "高", normal: "一般", later: "待辦" };

export function emptyState(): TopicState {
  return {
    doc: {
      v: 1,
      next_seq: 1,
      queues: { high: [], normal: [], later: [] },
      topics: {},
      merged: {},
      history: [],
      todos: {},
    },
    archive: { v: 1, topics: {} },
  };
}

export function isQueue(value: unknown): value is Queue {
  return typeof value === "string" && (QUEUES as readonly string[]).includes(value);
}

/** A usable topic id: the id grammar, and not the name of something every object inherits. */
export function isValidTopicId(id: string): boolean {
  return (
    id.length <= ID_MAX && /^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(id) && !(id in Object.prototype)
  );
}

/** Follows the merged table from `id` to the id that currently owns it. */
export function resolveTopicId(doc: TopicsDoc, id: string): string {
  let current = id;
  for (let hops = 0; hops < 64; hops += 1) {
    const next = doc.merged[current];
    if (next === undefined) return current;
    current = next;
  }
  return current;
}

function refuse(line: string): TopicResult {
  return { ok: false, code: "refused", line };
}

function unchanged(state: TopicState, line: string): TopicResult {
  return { ok: true, state, line, changed: false, events: [], dispatchable: [] };
}

function changed(
  state: TopicState,
  line: string,
  events: TopicEvent[] = [],
  dispatchable: string[] = [],
): TopicResult {
  return { ok: true, state, line, changed: true, events, dispatchable };
}

function clone(state: TopicState): TopicState {
  return structuredClone(state);
}

function codePoints(text: string): number {
  return [...text].length;
}

// Control characters (line breaks, tabs, terminal escapes) and the characters
// that reorder the text around them: a name is printed in terminals and tables.
const NOT_PLAIN_TEXT = /[\p{Cc}\u202A-\u202E\u2066-\u2069]/u;

/** Trims `text` and returns it when it is one non-empty line of plain text within `max` code points. */
export function oneLine(text: string, max: number): string | null {
  const trimmed = text.trim();
  if (trimmed === "" || NOT_PLAIN_TEXT.test(trimmed) || codePoints(trimmed) > max) return null;
  return trimmed;
}

function idInUse(state: TopicState, id: string): boolean {
  return (
    state.doc.topics[id] !== undefined ||
    state.archive.topics[id] !== undefined ||
    state.doc.merged[id] !== undefined
  );
}

function slugOf(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, ID_MAX - 4);
}

/** Picks a fresh id for `name`, advancing `next_seq` when the name has no usable slug. */
function mintId(state: TopicState, name: string): string {
  const slug = slugOf(name);
  if (slug === "") {
    for (;;) {
      const id = `t${state.doc.next_seq}`;
      state.doc.next_seq += 1;
      if (!idInUse(state, id)) return id;
    }
  }
  if (!idInUse(state, slug)) return slug;
  for (let n = 2; ; n += 1) {
    const id = `${slug}-${n}`;
    if (!idInUse(state, id)) return id;
  }
}

function queueOf(doc: TopicsDoc, id: string): Queue | undefined {
  return QUEUES.find((queue) => doc.queues[queue].includes(id));
}

function removeFromQueues(doc: TopicsDoc, id: string): void {
  for (const queue of QUEUES) {
    doc.queues[queue] = doc.queues[queue].filter((entry) => entry !== id);
  }
}

export interface CreateInput {
  name: string;
  goal: string;
  id?: string;
  /** The queue to land in; normal unless the caller names one. */
  queue?: Queue;
}

/** The id a new topic gets: the caller's `--id` when given and free, else a minted one. */
function chooseId(
  state: TopicState,
  name: string,
  wanted: string | undefined,
): string | TopicResult {
  if (wanted === undefined) return mintId(state, name);
  if (!isValidTopicId(wanted)) return refuse(`議題 id 格式不對：${wanted}`);
  if (idInUse(state, wanted)) return refuse(`議題 id ${wanted} 已經用過，不能重用。`);
  return wanted;
}

/**
 * Makes a new topic, confirmed and last in its queue: `normal` unless the
 * caller names another. A live topic with the same name and goal is the same
 * topic, so a repeat changes nothing and leaves it where it is.
 */
export function create(state: TopicState, input: CreateInput, now: string): TopicResult {
  const name = oneLine(input.name, NAME_MAX);
  const goal = oneLine(input.goal, GOAL_MAX);
  if (name === null) return refuse(`名稱要是一行、不能是空的、最多 ${NAME_MAX} 個字。`);
  if (goal === null) return refuse(`目標要是一行、不能是空的、最多 ${GOAL_MAX} 個字。`);
  const existing = Object.entries(state.doc.topics).find(
    ([, topic]) => topic.name === name && topic.goal === goal,
  );
  if (existing !== undefined) {
    const [id] = existing;
    const queue = queueOf(state.doc, id);
    const place = queue === undefined ? "沒有排進佇列" : `在「${QUEUE_LABEL[queue]}」`;
    return unchanged(state, `ok ${id} 本來就有這個議題，${place}`);
  }
  const next = clone(state);
  const id = chooseId(next, name, input.id);
  if (typeof id !== "string") return id;
  const queue = input.queue ?? "normal";
  next.doc.topics[id] = { name, goal, status: "confirmed", created_at: now };
  next.doc.queues[queue].push(id);
  const placed = `排在「${QUEUE_LABEL[queue]}」最後`;
  return changed(next, `ok ${id} 已建立，${placed}`, [
    { kind: "topic.created", topic: id, text: `議題「${name}」已建立，${placed}` },
  ]);
}

/** Why a topic that is not live cannot be acted on: it is archived, or it does not exist. */
function unusable(state: TopicState, id: string, rawId: string): TopicResult {
  if (state.archive.topics[id] !== undefined) return refuse(`議題 ${id} 已封存，要先 reopen。`);
  return missing(rawId);
}

function missing(id: string): TopicResult {
  return refuse(`沒有 ${id} 這個議題。用 list --all 看有哪些。`);
}

export function merge(
  state: TopicState,
  rawFrom: string,
  rawInto: string,
  now: string,
  reason?: string,
): TopicResult {
  const why = reasonOf(reason);
  if (why === null) return refuse(REASON_PROBLEM);
  const into = resolveTopicId(state.doc, rawInto);
  const from = resolveTopicId(state.doc, rawFrom);
  if (from === into) {
    if (state.doc.merged[rawFrom] !== undefined)
      return unchanged(state, `ok ${rawFrom} 本來就已併入 ${into}`);
    return refuse("不能把議題併進它自己。");
  }
  const target = state.doc.topics[into];
  if (target === undefined) return unusable(state, into, rawInto);
  const source = state.doc.topics[from];
  if (source === undefined) return unusable(state, from, rawFrom);
  const next = clone(state);
  delete next.doc.topics[from];
  removeFromQueues(next.doc, from);
  next.doc.merged[from] = into;
  next.doc.history.push({
    at: now,
    kind: "merged",
    topic: into,
    name: target.name,
    from,
    from_name: source.name,
    ...why,
  });
  return changed(next, `ok ${from} 已併入 ${into}`, [
    { kind: "topic.merged", topic: into, text: `議題「${source.name}」已併入「${target.name}」` },
  ]);
}

export interface SplitInput {
  from: string;
  name: string;
  goal: string;
  id?: string;
  /** Why the topic is being split, kept in the history. */
  reason?: string;
}

const REASON_PROBLEM = `原因要是一行，最多 ${GOAL_MAX} 個字。`;

/** The history fields for an optional reason: none when absent, null when it is not one line. */
function reasonOf(reason: string | undefined): { reason?: string } | null {
  if (reason === undefined) return {};
  const line = oneLine(reason, GOAL_MAX);
  return line === null ? null : { reason: line };
}

/**
 * Splits a new confirmed topic off `input.from`, placed right after it in the
 * same queue so work moved to it keeps its priority. Moving the tasks is the
 * caller's job; the history records only that the topic was split off.
 */
export function split(state: TopicState, input: SplitInput, now: string): TopicResult {
  const why = reasonOf(input.reason);
  if (why === null) return refuse(REASON_PROBLEM);
  const found = liveTopic(state, input.from);
  if ("ok" in found) return found;
  const name = oneLine(input.name, NAME_MAX);
  const goal = oneLine(input.goal, GOAL_MAX);
  if (name === null) return refuse(`名稱要是一行、不能是空的、最多 ${NAME_MAX} 個字。`);
  if (goal === null) return refuse(`目標要是一行、不能是空的、最多 ${GOAL_MAX} 個字。`);
  const earlier = state.doc.history.find(
    (entry) =>
      entry.kind === "split" &&
      entry.from !== undefined &&
      resolveTopicId(state.doc, entry.from) === found.id &&
      state.doc.topics[entry.topic]?.name === name,
  );
  if (earlier !== undefined)
    return unchanged(state, `ok ${earlier.topic} 本來就已從 ${found.id} 拆出`);
  const queue = QUEUES.find((entry) => state.doc.queues[entry].includes(found.id));
  if (queue === undefined) return refuse(`${found.id} 不在任何佇列裡，先用 move 把它排進去。`);
  const next = clone(state);
  const id = chooseId(next, name, input.id);
  if (typeof id !== "string") return id;
  next.doc.topics[id] = { name, goal, status: "confirmed", created_at: now };
  const order = next.doc.queues[queue];
  order.splice(order.indexOf(found.id) + 1, 0, id);
  next.doc.history.push({
    at: now,
    kind: "split",
    topic: id,
    name,
    from: found.id,
    from_name: found.topic.name,
    ...why,
  });
  return changed(next, `ok ${id} 已從 ${found.id} 拆出，放進「${QUEUE_LABEL[queue]}」`, [
    { kind: "topic.split", topic: id, text: `從議題「${found.topic.name}」拆出「${name}」` },
  ]);
}

function liveTopic(state: TopicState, rawId: string): { id: string; topic: Topic } | TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return unusable(state, id, rawId);
  return { id, topic };
}

export function closePropose(
  state: TopicState,
  rawId: string,
  rawReason: string,
  now: string,
): TopicResult {
  const found = liveTopic(state, rawId);
  if ("ok" in found) return found;
  const reason = oneLine(rawReason, GOAL_MAX);
  if (reason === null) return refuse(`理由要是一行、不能是空的、最多 ${GOAL_MAX} 個字。`);
  if (found.topic.close_proposal?.reason === reason)
    return unchanged(state, `ok ${found.id} 已經提議過關閉`);
  const next = clone(state);
  (next.doc.topics[found.id] as Topic).close_proposal = { at: now, reason };
  return changed(next, `ok ${found.id} 已提議關閉，等使用者決定`, [
    { kind: "topic.close_proposed", topic: found.id, text: `提議關閉：${reason}` },
  ]);
}

/** Where in the queue a moved topic lands; undefined keeps a topic already in the queue where it is. */
export type MovePosition = { first: true } | { last: true } | { before: string } | undefined;

function insertAt(
  queue: string[],
  id: string,
  position: MovePosition,
  doc: TopicsDoc,
): string[] | string {
  const without = queue.filter((entry) => entry !== id);
  if (position === undefined) return queue.includes(id) ? queue : [...without, id];
  if ("first" in position) return [id, ...without];
  if ("last" in position) return [...without, id];
  const anchor = resolveTopicId(doc, position.before);
  const at = without.indexOf(anchor);
  if (anchor === id || at === -1) return `--before 指的 ${position.before} 不在那個佇列裡。`;
  return [...without.slice(0, at), id, ...without.slice(at)];
}

export function move(
  state: TopicState,
  rawId: string,
  queue: Queue,
  position: MovePosition,
  now: string,
): TopicResult {
  const found = liveTopic(state, rawId);
  if ("ok" in found) return found;
  const { id } = found;
  const from = queueOf(state.doc, id);
  const target = insertAt(state.doc.queues[queue], id, position, state.doc);
  if (typeof target === "string") return refuse(target);
  if (from === queue && target.join("\n") === state.doc.queues[queue].join("\n")) {
    return unchanged(state, `ok ${id} 本來就在「${QUEUE_LABEL[queue]}」的這個位置`);
  }
  const next = clone(state);
  removeFromQueues(next.doc, id);
  next.doc.queues[queue] = target;
  const place = target.indexOf(id) + 1;
  const name = found.topic.name;
  next.doc.history.push({ at: now, kind: "moved", topic: id, name, queue, position: place });
  const dispatchable = from === "later" && queue !== "later" ? [id] : [];
  const text = `議題「${name}」移到「${QUEUE_LABEL[queue]}」第 ${place}`;
  return changed(
    next,
    `ok ${id} 已移到「${QUEUE_LABEL[queue]}」`,
    [{ kind: "topic.moved", topic: id, text }],
    dispatchable,
  );
}

function setText(
  state: TopicState,
  rawId: string,
  field: "name" | "goal",
  value: string,
  now: string,
): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return unusable(state, id, rawId);
  const max = field === "name" ? NAME_MAX : GOAL_MAX;
  const label = field === "name" ? "名稱" : "目標";
  const text = oneLine(value, max);
  if (text === null) return refuse(`${label}要是一行、不能是空的、最多 ${max} 個字。`);
  if (topic[field] === text) return unchanged(state, `ok ${id} ${label}沒有變`);
  const next = clone(state);
  (next.doc.topics[id] as Topic)[field] = text;
  if (field === "name") {
    next.doc.history.push({
      at: now,
      kind: "renamed",
      topic: id,
      name: text,
      from_name: topic.name,
    });
    return changed(next, `ok ${id} ${label}已改`, [
      { kind: "topic.renamed", topic: id, text: `議題「${topic.name}」改名為「${text}」` },
    ]);
  }
  next.doc.history.push({ at: now, kind: "goal", topic: id, name: topic.name, goal: text });
  return changed(next, `ok ${id} ${label}已改`, [
    { kind: "topic.goal_changed", topic: id, text: `議題「${topic.name}」的目標改為「${text}」` },
  ]);
}

export function rename(state: TopicState, rawId: string, name: string, now: string): TopicResult {
  return setText(state, rawId, "name", name, now);
}

export function setGoal(state: TopicState, rawId: string, goal: string, now: string): TopicResult {
  return setText(state, rawId, "goal", goal, now);
}

export function archive(state: TopicState, rawId: string, now: string): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  if (state.archive.topics[id] !== undefined) return unchanged(state, `ok ${id} 本來就已封存`);
  const topic = state.doc.topics[id];
  if (topic === undefined) return missing(rawId);
  const next = clone(state);
  const { close_proposal: _dropped, ...kept } = topic;
  void _dropped;
  next.archive.topics[id] = { ...kept, archived_at: now };
  delete next.doc.topics[id];
  removeFromQueues(next.doc, id);
  const why = topic.close_proposal === undefined ? {} : { reason: topic.close_proposal.reason };
  next.doc.history.push({ at: now, kind: "archived", topic: id, name: topic.name, ...why });
  return changed(next, `ok ${id} 已封存`, [
    { kind: "topic.archived", topic: id, text: `議題「${topic.name}」已封存` },
  ]);
}

export function reopen(
  state: TopicState,
  rawId: string,
  queue: Queue | undefined,
  now: string,
): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const archived = state.archive.topics[id];
  if (archived === undefined) {
    if (state.doc.topics[id] !== undefined) return unchanged(state, `ok ${id} 本來就沒有封存`);
    return missing(rawId);
  }
  const next = clone(state);
  const target = queue === undefined ? "normal" : queue;
  const { archived_at: _dropped, ...kept } = archived;
  void _dropped;
  next.doc.topics[id] = { ...kept, status: "confirmed" };
  next.doc.history.push({ at: now, kind: "reopened", topic: id, name: archived.name });
  delete next.archive.topics[id];
  next.doc.queues[target].push(id);
  const dispatchable = target === "later" ? [] : [id];
  return changed(
    next,
    `ok ${id} 已重開，放進「${QUEUE_LABEL[target]}」`,
    [
      {
        kind: "topic.reopened",
        topic: id,
        text: `議題「${archived.name}」已重開，放進「${QUEUE_LABEL[target]}」`,
      },
    ],
    dispatchable,
  );
}

/** Turns down firstmate's proposal to close a topic. */
export function keepOpen(state: TopicState, rawId: string): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return unusable(state, id, rawId);
  if (topic.close_proposal === undefined) return unchanged(state, `ok ${id} 沒有關閉的提議`);
  const next = clone(state);
  delete (next.doc.topics[id] as Topic).close_proposal;
  return changed(next, `ok ${id} 先不關`);
}

export interface TodoInput {
  task: string;
  state: TodoState;
  /** Why firstmate rejected the claim or no longer needs the item. */
  reason?: string;
  /** Tasks whose hold is gone, so their marks can go too. */
  gone?: string[];
}

const TODO_LINE: Record<TodoState, string> = {
  claimed: "已記下做完了，等 first mate 驗證",
  rejected: "已標成驗證沒過，回到要使用者動手",
  obsolete: "已標成不再需要，等使用者撤下",
};

/** The mark an input asks for, or null when it lacks the one-line reason it needs. */
function todoMark(input: TodoInput, now: string): TodoMark | null {
  if (input.state === "claimed") return { state: input.state, at: now };
  const reason = oneLine(input.reason ?? "", GOAL_MAX);
  return reason === null ? null : { state: input.state, at: now, reason };
}

/** The tasks in `gone` that still carry a mark, leaving out the one being marked. */
function staleTodos(state: TopicState, input: TodoInput): string[] {
  return (input.gone ?? []).filter(
    (task) => task !== input.task && Object.hasOwn(state.doc.todos, task),
  );
}

/** Records where a hands-on item stands. Repeating the same mark changes nothing. */
export function markTodo(state: TopicState, input: TodoInput, now: string): TopicResult {
  // Assigning to this key would set the object's prototype instead of storing a mark.
  if (input.task === "__proto__") return refuse("看板不能記這個 task id 的狀態。");
  const mark = todoMark(input, now);
  if (mark === null) return refuse(`原因要是一行，最多 ${GOAL_MAX} 個字。`);
  const todos = state.doc.todos;
  const current = Object.hasOwn(todos, input.task) ? todos[input.task] : undefined;
  const same = current?.state === mark.state && current.reason === mark.reason;
  const gone = staleTodos(state, input);
  if (same && gone.length === 0)
    return unchanged(state, `ok ${input.task} 本來就${TODO_LINE[mark.state]}`);
  const next = clone(state);
  for (const task of gone) delete next.doc.todos[task];
  if (!same) next.doc.todos[input.task] = mark;
  return changed(next, `ok ${input.task} ${TODO_LINE[mark.state]}`);
}

/** Forgets a hands-on item's mark, so it reads as still to do: its text was just rewritten. */
export function clearTodo(state: TopicState, task: string): TopicResult {
  if (!Object.hasOwn(state.doc.todos, task)) return unchanged(state, `ok ${task} 本來就沒有狀態`);
  const next = clone(state);
  delete next.doc.todos[task];
  return changed(next, `ok ${task} 回到還沒做`);
}

/** Marks the history entries a change just added with where the change was made. */
export function stampHistory(result: TopicResult, before: number, by: HistoryActor): TopicResult {
  if (!result.ok || !result.changed || result.state.doc.history.length <= before) return result;
  const state = clone(result.state);
  for (const entry of state.doc.history.slice(before)) entry.by = by;
  return { ...result, state };
}
