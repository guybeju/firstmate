// Loads and saves the topic files. The service is their only writer.
import fs from "node:fs";
import {
  isRecord,
  readJsonFile,
  stringField,
  stringRecord,
  textField,
  writeFileAtomic,
} from "./files.js";
import type { BoardPaths } from "./layout.js";
import {
  GOAL_MAX,
  HISTORY_ACTORS,
  HISTORY_KINDS,
  QUEUES,
  TODO_STATES,
  emptyState,
  isQueue,
  oneLine,
} from "./topics.js";
import type {
  ArchiveDoc,
  ArchivedTopic,
  HistoryEntry,
  TodoMark,
  Topic,
  TopicState,
  TopicsDoc,
} from "./topics.js";

const FILE_MODE = 0o644;

function parseCloseProposal(raw: unknown): Topic["close_proposal"] {
  if (!isRecord(raw) || typeof raw["at"] !== "string" || typeof raw["reason"] !== "string")
    return undefined;
  return { at: raw["at"], reason: raw["reason"] };
}

function parseStatus(id: string, raw: unknown): Topic["status"] {
  if (raw !== "proposed" && raw !== "confirmed")
    throw new Error(`topic ${id} has an unknown status`);
  return raw;
}

function parseTopic(id: string, raw: unknown): Topic {
  if (!isRecord(raw)) throw new Error(`topic ${id} is not an object`);
  const { name, goal } = raw;
  if (typeof name !== "string" || typeof goal !== "string")
    throw new Error(`topic ${id} lacks name or goal`);
  const topic: Topic = {
    name,
    goal,
    status: parseStatus(id, raw["status"]),
    created_at: textField(raw, "created_at"),
    proposed_by: raw["proposed_by"] === "user" ? "user" : "firstmate",
  };
  if (isQueue(raw["suggested_queue"])) topic.suggested_queue = raw["suggested_queue"];
  const close = parseCloseProposal(raw["close_proposal"]);
  if (close !== undefined) topic.close_proposal = close;
  return topic;
}

/** A queue only ever holds confirmed topics, each once. */
function parseQueue(raw: unknown, topics: Record<string, Topic>): string[] {
  if (!Array.isArray(raw)) return [];
  return [...new Set(raw)].filter(
    (id): id is string => typeof id === "string" && topics[id]?.status === "confirmed",
  );
}

function parseNextSeq(raw: unknown): number {
  return typeof raw === "number" && Number.isInteger(raw) ? Math.max(1, raw) : 1;
}

function parseHistoryEntry(raw: unknown): HistoryEntry | null {
  if (!isRecord(raw)) return null;
  const kind = HISTORY_KINDS.find((name) => name === raw["kind"]);
  const at = stringField(raw, "at");
  const topic = stringField(raw, "topic");
  const name = stringField(raw, "name");
  if (kind === undefined || at === null || topic === null || name === null) return null;
  const entry: HistoryEntry = { at, kind, topic, name };
  const from = stringField(raw, "from");
  const fromName = stringField(raw, "from_name");
  if (from !== null) entry.from = from;
  if (fromName !== null) entry.from_name = fromName;
  // A reason someone edited into something that is not one line is dropped, not printed.
  const reason = oneLine(stringField(raw, "reason") ?? "", GOAL_MAX);
  const by = HISTORY_ACTORS.find((actor) => actor === raw["by"]);
  if (reason !== null) entry.reason = reason;
  if (by !== undefined) entry.by = by;
  return entry;
}

function parseHistory(raw: unknown): HistoryEntry[] {
  if (!Array.isArray(raw)) return [];
  return raw.map(parseHistoryEntry).filter((entry): entry is HistoryEntry => entry !== null);
}

function parseTodos(raw: unknown): Record<string, TodoMark> {
  const todos: Record<string, TodoMark> = {};
  if (!isRecord(raw)) return todos;
  for (const [task, value] of Object.entries(raw)) {
    if (!isRecord(value) || task === "__proto__") continue;
    const state = TODO_STATES.find((name) => name === value["state"]);
    const at = stringField(value, "at");
    if (state === undefined || at === null) continue;
    const reason = stringField(value, "reason");
    todos[task] = reason === null ? { state, at } : { state, at, reason };
  }
  return todos;
}

function parseDoc(raw: unknown): TopicsDoc {
  if (!isRecord(raw) || raw["v"] !== 1) throw new Error("expected an object with v: 1");
  const topics = raw["topics"];
  if (!isRecord(topics)) throw new Error("topics is not an object");
  const doc = emptyState().doc;
  for (const [id, topic] of Object.entries(topics)) doc.topics[id] = parseTopic(id, topic);
  const queues = isRecord(raw["queues"]) ? raw["queues"] : {};
  for (const queue of QUEUES) doc.queues[queue] = parseQueue(queues[queue], doc.topics);
  doc.merged = stringRecord(raw["merged"]);
  doc.history = parseHistory(raw["history"]);
  doc.todos = parseTodos(raw["todos"]);
  doc.next_seq = parseNextSeq(raw["next_seq"]);
  return doc;
}

function parseArchive(raw: unknown): ArchiveDoc {
  if (!isRecord(raw) || raw["v"] !== 1 || !isRecord(raw["topics"])) {
    throw new Error("expected an object with v: 1 and topics");
  }
  const archive: ArchiveDoc = { v: 1, topics: {} };
  for (const [id, topic] of Object.entries(raw["topics"])) {
    const parsed = parseTopic(id, topic);
    const archived: ArchivedTopic = {
      ...parsed,
      archived_at: textField(topic as Record<string, unknown>, "archived_at"),
    };
    archive.topics[id] = archived;
  }
  return archive;
}

function loadFile<T>(file: string, parse: (raw: unknown) => T, fallback: T): T {
  let raw: unknown;
  try {
    raw = readJsonFile(file);
  } catch (error) {
    throw new Error(`${file} 讀不懂：${(error as Error).message}`, { cause: error });
  }
  if (raw === null) return fallback;
  try {
    return parse(raw);
  } catch (error) {
    throw new Error(`${file} 讀不懂：${(error as Error).message}`, { cause: error });
  }
}

export function loadTopicState(paths: BoardPaths): TopicState {
  const empty = emptyState();
  const state: TopicState = {
    doc: loadFile(paths.topics, parseDoc, empty.doc),
    archive: loadFile(paths.archive, parseArchive, empty.archive),
  };
  // A crash between the two writes of an archive or reopen can leave a topic in
  // both files. The live copy wins: an interrupted archive is simply redone,
  // and an interrupted reopen is already complete.
  for (const id of Object.keys(state.archive.topics)) {
    if (state.doc.topics[id] !== undefined) delete state.archive.topics[id];
  }
  return state;
}

function serialize(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

/** Writes whichever of the two files changed, the file gaining a topic first. */
export function saveTopicState(paths: BoardPaths, previous: TopicState, next: TopicState): void {
  fs.mkdirSync(paths.dataDir, { recursive: true });
  const docText = serialize(next.doc);
  const archiveText = serialize(next.archive);
  const writeDoc = (): void => {
    if (docText !== serialize(previous.doc)) writeFileAtomic(paths.topics, docText, FILE_MODE);
  };
  const writeArchive = (): void => {
    if (archiveText !== serialize(previous.archive))
      writeFileAtomic(paths.archive, archiveText, FILE_MODE);
  };
  const archiveGained = Object.keys(next.archive.topics).some(
    (id) => previous.archive.topics[id] === undefined,
  );
  if (archiveGained) {
    writeArchive();
    writeDoc();
  } else {
    writeDoc();
    writeArchive();
  }
}
