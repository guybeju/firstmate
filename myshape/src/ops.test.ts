// Guard 3.1: every operation in the table, run once through the real commit
// into a scratch directory, saves a change with a record; run again with the
// same arguments, it changes nothing. An operation without a fixture here
// does not compile.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Journal } from "./journal.js";
import { boardPaths } from "./layout.js";
import type { BoardPaths } from "./layout.js";
import { OPERATIONS, applyOperation, assertUnchanged } from "./ops.js";
import type { OperationName } from "./ops.js";
import { RECORD_KINDS } from "./records.js";
import type { StoredRecord } from "./records.js";
import { readBoard } from "./store.js";
import type { CommitTarget, StoredBoard } from "./store.js";
import { emptyTodos } from "./todos.js";
import type { TodoItem, TodoStore } from "./todos.js";
import { emptyState } from "./topics.js";
import type { TopicState } from "./topics.js";

const WHO = { label: "first mate", agent: "firstmate", now: "2026-11-21T00:00:00Z" };

interface Fixture {
  args: Record<string, unknown>;
  fromPage: boolean;
}

const FIXTURES = {
  create: { args: { name: "New", goal: "g" }, fromPage: false },
  merge: { args: { from: "b", into: "a" }, fromPage: true },
  "close-propose": { args: { id: "a", reason: "都做完了" }, fromPage: false },
  move: { args: { id: "c", queue: "normal" }, fromPage: true },
  split: { args: { from: "a", name: "Part", goal: "g" }, fromPage: false },
  rename: { args: { id: "a", value: "A two" }, fromPage: true },
  goal: { args: { id: "a", value: "new goal" }, fromPage: false },
  archive: { args: { id: "a" }, fromPage: true },
  keep: { args: { id: "b" }, fromPage: true },
  reopen: { args: { id: "z" }, fromPage: false },
  "todo-add": {
    args: { id: "fresh", title: "登入", topic: "a", action: "登入 VPN", commands: [] },
    fromPage: false,
  },
  "todo-done": { args: { task: "claimed" }, fromPage: false },
  "todo-failed": { args: { task: "claimed", reason: "沒起來" }, fromPage: false },
  "todo-obsolete": { args: { task: "open", reason: "不用了" }, fromPage: false },
  "todo-adopt-done": { args: { open: [] }, fromPage: false },
  "todo-claim": { args: { task: "open" }, fromPage: true },
  "todo-drop": { args: { task: "open" }, fromPage: true },
  "todo-takedown": { args: { task: "obsolete" }, fromPage: true },
} satisfies Record<OperationName, Fixture>;

function topicsFixture(): TopicState {
  const state = emptyState();
  const topic = (name: string) => ({
    name,
    goal: "g",
    status: "confirmed" as const,
    created_at: "T",
  });
  state.doc.topics = {
    a: topic("A"),
    b: { ...topic("B"), close_proposal: { at: "T", reason: "做完了" } },
    c: topic("C"),
  };
  state.doc.queues = { high: ["a"], normal: ["b"], later: ["c"] };
  state.archive.topics = { z: { ...topic("Z"), archived_at: "T" } };
  return state;
}

function item(state: TodoItem["state"], extra: Partial<TodoItem> = {}): TodoItem {
  return {
    title: `項目 ${state}`,
    topic: "a",
    action: "做",
    guidance: "",
    commands: [],
    state,
    reason: null,
    at: "T",
    by: "firstmate",
    ref: "",
    captain_closes: false,
    adopted: false,
    created_at: "T",
    ...extra,
  };
}

function todosFixture(): TodoStore {
  return {
    ...emptyTodos(),
    items: {
      open: item("open"),
      claimed: item("claimed"),
      obsolete: item("obsolete", { captain_closes: true, reason: "不用了" }),
      adopted: item("open", { adopted: true, ref: "hold" }),
    },
  };
}

let dir: string;
let paths: BoardPaths;
let journal: Journal;
let target: CommitTarget;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-ops-"));
  paths = boardPaths({ state: path.join(dir, "state"), data: path.join(dir, "data") });
  fs.mkdirSync(paths.boardDataDir, { recursive: true });
  const write = (file: string, value: unknown): void =>
    fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  const topics = topicsFixture();
  write(paths.topics, topics.doc);
  write(paths.archive, topics.archive);
  write(paths.todos, todosFixture());
  journal = new Journal(paths.events);
  let n = 0;
  target = {
    paths,
    sink: {
      has: (rid) => journal.hasRecord(rid),
      append: (record) => journal.appendRecord(record),
    },
    nextRid: () => `r-ops-${(n += 1)}`,
    nowSeconds: () => 1_795_200_000,
  };
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

function files(): Record<string, string | null> {
  const read = (file: string): string | null =>
    fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
  return {
    topics: read(paths.topics),
    archive: read(paths.archive),
    todos: read(paths.todos),
    events: read(paths.events),
  };
}

function journalLines(): StoredRecord[] {
  const text = files()["events"] ?? "";
  return text === ""
    ? []
    : text
        .trimEnd()
        .split("\n")
        .map((line) => JSON.parse(line) as StoredRecord);
}

function run(board: StoredBoard, op: OperationName) {
  const { args, fromPage } = FIXTURES[op];
  return applyOperation(target, board, { op, args, fromPage }, WHO);
}

describe("every operation in the table", () => {
  it("has a fixture, and nothing else does", () => {
    expect(Object.keys(FIXTURES).toSorted()).toEqual(Object.keys(OPERATIONS).toSorted());
  });

  for (const op of Object.keys(FIXTURES) as OperationName[]) {
    it(`${op} saves its change with a record, and changes nothing the second time`, () => {
      const before = files();
      const first = run(readBoard(paths).board, op);
      expect(first.response).toMatchObject({ ok: true });
      const commitFile = OPERATIONS[op].commitFile;
      expect(first.committed).toBe(commitFile);
      const after = files();
      expect(after[commitFile]).not.toBe(before[commitFile]);
      const lines = journalLines();
      expect(lines.length).toBeGreaterThan(0);
      const outbox = (JSON.parse(after[commitFile] as string) as { outbox: StoredRecord[] }).outbox;
      for (const line of lines) {
        expect(line.rid).toMatch(/^r-ops-\d+$/);
        expect(line.by).toBe(FIXTURES[op].fromPage ? "captain" : "aggregator");
        expect(line.label).toBe("first mate");
        expect(line.ts).toBe(1_795_200_000);
        expect(RECORD_KINDS).toContain(line.kind);
        expect(line.topic !== null || line.item !== undefined).toBe(true);
        expect(outbox.map((record) => record.rid)).toContain(line.rid);
      }
      const again = run(readBoard(paths).board, op);
      expect(again.committed).toBeNull();
      expect(files()).toEqual(after);
    });
  }

  it("refuses the captain's presses over the socket and the agent's commands from the page", () => {
    const board = readBoard(paths).board;
    const socket = applyOperation(
      target,
      board,
      { op: "keep", args: { id: "b" }, fromPage: false },
      WHO,
    );
    expect(socket.response).toEqual({
      ok: false,
      code: "refused",
      line: "keep 是使用者在頁面上按的，不能從指令送。",
    });
    const page = applyOperation(
      target,
      board,
      { op: "create", args: { name: "N", goal: "g" }, fromPage: true },
      WHO,
    );
    expect(page.response).toEqual({ ok: false, code: "refused", line: "create 只能從指令送。" });
    const unknown = applyOperation(target, board, { op: "nope", args: {}, fromPage: false }, WHO);
    expect(unknown.response).toEqual({ ok: false, code: "usage", line: "不認得的 op：nope" });
    expect(journalLines()).toEqual([]);
  });

  it("marks a topic record with who made it, and a hands-on record under the topic it shows in", () => {
    const board = readBoard(paths).board;
    const page = run(board, "rename");
    expect(page.records[0]?.text).toBe("議題「A」改名為「A two」（你在頁面上）");
    expect(page.decisions).toEqual([]);
    const kept = run(page.board, "keep");
    expect(kept.records[0]?.text).toBe("議題「B」先不關（你在頁面上）");
    expect(kept.decisions).toEqual([
      { event: "topic.kept", topic: "b", line: "議題「B」先不關（id：b）" },
    ]);
    const merged = run(kept.board, "merge");
    expect(merged.decisions).toEqual([
      { event: "topic.merged", topic: "a", line: "議題「B」已併入「A two」（id：a）" },
    ]);
    const command = run(merged.board, "goal");
    expect(command.records[0]?.text).toBe(
      "議題「A two」的目標改為「new goal」（first mate 用指令）",
    );
    expect(command.decisions).toEqual([]);
    const claimed = run(command.board, "todo-claim");
    expect(claimed.records[0]).toMatchObject({ kind: "todo.claimed", item: "open", topic: "a" });
    expect(claimed.notices).toHaveLength(1);
  });

  it("says why a malformed request is refused, and changes nothing", () => {
    const board = readBoard(paths).board;
    const cases: [OperationName, Record<string, unknown>][] = [
      ["create", { name: "N" }],
      ["merge", { from: "a" }],
      ["todo-add", { id: "x" }],
      ["todo-failed", { task: "claimed" }],
    ];
    for (const [op, args] of cases) {
      const result = applyOperation(target, board, { op, args, fromPage: false }, WHO);
      expect(result.response).toMatchObject({ ok: false, code: "usage" });
      expect(result.committed).toBeNull();
    }
    expect(journalLines()).toEqual([]);
  });
});

describe("a result that says it changed nothing", () => {
  it("must hand back the state it was given", () => {
    expect(() => assertUnchanged("op", { a: 1 }, { a: 1 })).not.toThrow();
    expect(() => assertUnchanged("op", { a: 1 }, { a: 2 })).toThrow("op 說沒有改任何東西");
  });
});
