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
  status: "proposed" | "confirmed";
  created_at: string;
  proposed_by: "firstmate" | "user";
  suggested_queue?: Queue;
  close_proposal?: CloseProposal;
}

export interface ArchivedTopic extends Topic {
  archived_at: string;
}

export interface TopicsDoc {
  v: 1;
  next_seq: number;
  queues: Record<Queue, string[]>;
  topics: Record<string, Topic>;
  merged: Record<string, string>;
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
  | "topic.confirmed"
  | "topic.merged"
  | "topic.close_proposed"
  | "topic.archived"
  | "topic.reopened";

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
const QUEUE_LABEL: Record<Queue, string> = { high: "高", normal: "一般", later: "待辦" };

export function emptyState(): TopicState {
  return {
    doc: { v: 1, next_seq: 1, queues: { high: [], normal: [], later: [] }, topics: {}, merged: {} },
    archive: { v: 1, topics: {} },
  };
}

export function isQueue(value: unknown): value is Queue {
  return typeof value === "string" && (QUEUES as readonly string[]).includes(value);
}

export function isValidTopicId(id: string): boolean {
  return id.length <= ID_MAX && /^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(id);
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

/** Trims `text` and returns it when it is one non-empty line within `max` code points. */
function oneLine(text: string, max: number): string | null {
  const trimmed = text.trim();
  if (trimmed === "" || /[\r\n]/.test(trimmed) || codePoints(trimmed) > max) return null;
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

function queueOf(doc: TopicsDoc, id: string): Queue | null {
  return QUEUES.find((queue) => doc.queues[queue].includes(id)) ?? null;
}

function removeFromQueues(doc: TopicsDoc, id: string): void {
  for (const queue of QUEUES) {
    doc.queues[queue] = doc.queues[queue].filter((entry) => entry !== id);
  }
}

export interface ProposeInput {
  name: string;
  goal: string;
  id?: string;
  queue?: Queue;
  by: "firstmate" | "user";
}

/** The id a new topic gets: the caller's `--id` when given and free, else a minted one. */
function chooseId(state: TopicState, name: string, wanted: string | undefined): string | TopicResult {
  if (wanted === undefined) return mintId(state, name);
  if (!isValidTopicId(wanted)) return refuse(`議題 id 格式不對：${wanted}`);
  if (idInUse(state, wanted)) return refuse(`議題 id ${wanted} 已經用過，不能重用。`);
  return wanted;
}

export function propose(state: TopicState, input: ProposeInput, now: string): TopicResult {
  const name = oneLine(input.name, NAME_MAX);
  const goal = oneLine(input.goal, GOAL_MAX);
  if (name === null) return refuse(`名稱要是一行、不能是空的、最多 ${NAME_MAX} 個字。`);
  if (goal === null) return refuse(`目標要是一行、不能是空的、最多 ${GOAL_MAX} 個字。`);
  const existing = Object.entries(state.doc.topics).find(
    ([, topic]) => topic.status === "proposed" && topic.name === name && topic.goal === goal,
  );
  if (existing !== undefined) return unchanged(state, `ok ${existing[0]} 已經提議過，等使用者確認`);
  const next = clone(state);
  const id = chooseId(next, name, input.id);
  if (typeof id !== "string") return id;
  const topic: Topic = { name, goal, status: "proposed", created_at: now, proposed_by: input.by };
  if (input.queue !== undefined) topic.suggested_queue = input.queue;
  next.doc.topics[id] = topic;
  return changed(next, `ok ${id} 已提議，等使用者確認`);
}

function archivedRefusal(state: TopicState, id: string): TopicResult | null {
  if (state.archive.topics[id] === undefined) return null;
  return refuse(`議題 ${id} 已封存，要先 reopen。`);
}

function missing(id: string): TopicResult {
  return refuse(`沒有 ${id} 這個議題。用 list --all 看有哪些。`);
}

export function confirm(state: TopicState, rawId: string, queue: Queue | undefined): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return archivedRefusal(state, id) ?? missing(rawId);
  if (topic.status === "confirmed") return unchanged(state, `ok ${id} 本來就已確認`);
  const next = clone(state);
  const target = queue ?? topic.suggested_queue ?? "normal";
  const confirmed = next.doc.topics[id] as Topic;
  confirmed.status = "confirmed";
  next.doc.queues[target].push(id);
  return changed(next, `ok ${id} 已確認，放進「${QUEUE_LABEL[target]}」`, [
    { kind: "topic.confirmed", topic: id, text: `議題「${topic.name}」已確認，放進「${QUEUE_LABEL[target]}」` },
  ]);
}

export function merge(state: TopicState, rawFrom: string, rawInto: string): TopicResult {
  const into = resolveTopicId(state.doc, rawInto);
  const from = resolveTopicId(state.doc, rawFrom);
  if (from === into) {
    if (state.doc.merged[rawFrom] !== undefined) return unchanged(state, `ok ${rawFrom} 本來就已併入 ${into}`);
    return refuse("不能把議題併進它自己。");
  }
  const target = state.doc.topics[into];
  if (target === undefined) return archivedRefusal(state, into) ?? missing(rawInto);
  if (target.status !== "confirmed") return refuse(`${into} 還在提議中，只能併進已確認的議題。`);
  const source = state.doc.topics[from];
  if (source === undefined) return archivedRefusal(state, from) ?? missing(rawFrom);
  const next = clone(state);
  delete next.doc.topics[from];
  removeFromQueues(next.doc, from);
  next.doc.merged[from] = into;
  return changed(next, `ok ${from} 已併入 ${into}`, [
    { kind: "topic.merged", topic: into, text: `議題「${source.name}」已併入「${target.name}」` },
  ]);
}

function confirmedTopic(state: TopicState, rawId: string): { id: string; topic: Topic } | TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return archivedRefusal(state, id) ?? missing(rawId);
  if (topic.status !== "confirmed") return refuse(`${id} 還在提議中，要先 confirm。`);
  return { id, topic };
}

export function closePropose(state: TopicState, rawId: string, rawReason: string, now: string): TopicResult {
  const found = confirmedTopic(state, rawId);
  if ("ok" in found) return found;
  const reason = oneLine(rawReason, GOAL_MAX);
  if (reason === null) return refuse(`理由要是一行、不能是空的、最多 ${GOAL_MAX} 個字。`);
  if (found.topic.close_proposal?.reason === reason) return unchanged(state, `ok ${found.id} 已經提議過關閉`);
  const next = clone(state);
  (next.doc.topics[found.id] as Topic).close_proposal = { at: now, reason };
  return changed(next, `ok ${found.id} 已提議關閉，等使用者決定`, [
    { kind: "topic.close_proposed", topic: found.id, text: `first mate 提議關閉：${reason}` },
  ]);
}

/** Where in the queue a moved topic lands; undefined keeps a topic already in the queue where it is. */
export type MovePosition = { first: true } | { last: true } | { before: string } | undefined;

function insertAt(queue: string[], id: string, position: MovePosition, doc: TopicsDoc): string[] | string {
  const without = queue.filter((entry) => entry !== id);
  if (position === undefined) return queue.includes(id) ? queue : [...without, id];
  if ("first" in position) return [id, ...without];
  if ("last" in position) return [...without, id];
  const anchor = resolveTopicId(doc, position.before);
  const at = without.indexOf(anchor);
  if (anchor === id || at === -1) return `--before 指的 ${position.before} 不在那個佇列裡。`;
  return [...without.slice(0, at), id, ...without.slice(at)];
}

export function move(state: TopicState, rawId: string, queue: Queue, position: MovePosition): TopicResult {
  const found = confirmedTopic(state, rawId);
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
  const dispatchable = from === "later" && queue !== "later" ? [id] : [];
  return changed(next, `ok ${id} 已移到「${QUEUE_LABEL[queue]}」`, [], dispatchable);
}

function setText(state: TopicState, rawId: string, field: "name" | "goal", value: string): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return archivedRefusal(state, id) ?? missing(rawId);
  const max = field === "name" ? NAME_MAX : GOAL_MAX;
  const label = field === "name" ? "名稱" : "目標";
  const text = oneLine(value, max);
  if (text === null) return refuse(`${label}要是一行、不能是空的、最多 ${max} 個字。`);
  if (topic[field] === text) return unchanged(state, `ok ${id} ${label}沒有變`);
  const next = clone(state);
  (next.doc.topics[id] as Topic)[field] = text;
  return changed(next, `ok ${id} ${label}已改`);
}

export function rename(state: TopicState, rawId: string, name: string): TopicResult {
  return setText(state, rawId, "name", name);
}

export function setGoal(state: TopicState, rawId: string, goal: string): TopicResult {
  return setText(state, rawId, "goal", goal);
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
  return changed(next, `ok ${id} 已封存`, [
    { kind: "topic.archived", topic: id, text: `議題「${topic.name}」已封存` },
  ]);
}

export function reopen(state: TopicState, rawId: string, queue: Queue | undefined): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const archived = state.archive.topics[id];
  if (archived === undefined) {
    if (state.doc.topics[id] !== undefined) return unchanged(state, `ok ${id} 本來就沒有封存`);
    return missing(rawId);
  }
  const next = clone(state);
  const target = queue ?? "normal";
  const { archived_at: _dropped, ...kept } = archived;
  void _dropped;
  next.doc.topics[id] = { ...kept, status: "confirmed" };
  delete next.archive.topics[id];
  next.doc.queues[target].push(id);
  const dispatchable = target === "later" ? [] : [id];
  return changed(
    next,
    `ok ${id} 已重開，放進「${QUEUE_LABEL[target]}」`,
    [{ kind: "topic.reopened", topic: id, text: `議題「${archived.name}」已重開，放進「${QUEUE_LABEL[target]}」` }],
    dispatchable,
  );
}

/** Turns down firstmate's proposal to close a topic. */
export function keepOpen(state: TopicState, rawId: string): TopicResult {
  const id = resolveTopicId(state.doc, rawId);
  const topic = state.doc.topics[id];
  if (topic === undefined) return archivedRefusal(state, id) ?? missing(rawId);
  if (topic.close_proposal === undefined) return unchanged(state, `ok ${id} 沒有關閉的提議`);
  const next = clone(state);
  delete (next.doc.topics[id] as Topic).close_proposal;
  return changed(next, `ok ${id} 先不關`);
}
