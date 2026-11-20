import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as files from "./files.js";
import { Journal, Offsets, Summaries } from "./journal.js";
import { boardPaths, parseConfigArgs } from "./layout.js";
import type { BoardPaths } from "./layout.js";
import { loadTopicState, saveTopicState } from "./store.js";
import { archive, create, emptyState } from "./topics.js";
import type { TopicResult, TopicState } from "./topics.js";

let dir: string;
let paths: BoardPaths;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-storage-"));
  paths = boardPaths({ state: path.join(dir, "state"), data: path.join(dir, "data") });
  fs.mkdirSync(paths.boardDataDir, { recursive: true });
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

const mode = (file: string): number => fs.statSync(file).mode & 0o777;

describe("files", () => {
  it("replaces a file atomically with the given mode and leaves no temp file", () => {
    const file = path.join(dir, "f.json");
    files.writeFileAtomic(file, "one", 0o600);
    files.writeFileAtomic(file, "two", 0o600);
    expect(fs.readFileSync(file, "utf8")).toBe("two");
    expect(mode(file)).toBe(0o600);
    expect(fs.readdirSync(dir).filter((name) => name.includes(".tmp-"))).toEqual([]);
  });

  it("removes only stale temp files", () => {
    for (const name of ["a.json.tmp-123", "b.tmp-9", "keep.json", "c.tmp-x", "tmp-5"])
      fs.writeFileSync(path.join(dir, name), "");
    expect(files.removeStaleTemps(dir).toSorted()).toEqual(["a.json.tmp-123", "b.tmp-9"]);
    expect(fs.readdirSync(dir).toSorted()).toEqual(["c.tmp-x", "data", "keep.json", "tmp-5"]);
    expect(files.removeStaleTemps(path.join(dir, "missing"))).toEqual([]);
  });

  it("returns complete lines and cuts off a half-written last line", () => {
    const file = path.join(dir, "log.jsonl");
    expect(files.readCompleteLines(file)).toEqual([]);
    fs.writeFileSync(file, "one\ntwo\nthr");
    expect(files.readCompleteLines(file)).toEqual(["one", "two"]);
    expect(fs.readFileSync(file, "utf8")).toBe("one\ntwo\n");
    expect(files.readCompleteLines(file)).toEqual(["one", "two"]);
    fs.writeFileSync(file, "half");
    expect(files.readCompleteLines(file)).toEqual([]);
    expect(fs.readFileSync(file, "utf8")).toBe("");
    fs.writeFileSync(file, "one\n");
    expect(files.readCompleteLines(file)).toEqual(["one"]);
  });

  it("appends lines, creating the directory and applying the mode", () => {
    const file = path.join(dir, "deep", "er", "log");
    files.appendLine(file, "a", 0o600);
    files.appendLine(file, "b", 0o600);
    expect(fs.readFileSync(file, "utf8")).toBe("a\nb\n");
    expect(mode(file)).toBe(0o600);
    expect(files.fileSize(file)).toBe(4);
    expect(files.fileSize(path.join(dir, "missing"))).toBe(0);
  });

  it("reads JSON, pids, and typed fields defensively", () => {
    const file = path.join(dir, "x");
    expect(files.readJsonFile(file)).toBeNull();
    expect(files.readPidFile(file)).toBeNull();
    fs.writeFileSync(file, "1\n");
    expect(files.readPidFile(file)).toBe(1);
    fs.writeFileSync(file, "42\n");
    expect(files.readJsonFile(file)).toBe(42);
    expect(files.readPidFile(file)).toBe(42);
    for (const bad of ["0", "-3", "1.5", "abc", ""]) {
      fs.writeFileSync(file, bad);
      expect(files.readPidFile(file)).toBeNull();
    }
    expect(files.isAlive(process.pid)).toBe(true);
    expect(files.isAlive(2 ** 22 + 12345)).toBe(false);
    expect(files.isRecord({})).toBe(true);
    expect([null, [], "s", 1].map(files.isRecord)).toEqual([false, false, false, false]);
    expect(files.stringField({ a: "x", b: 1 }, "a")).toBe("x");
    expect(files.stringField({ a: "x", b: 1 }, "b")).toBeNull();
    expect(files.stringField({}, "a")).toBeNull();
    expect(files.textField({ a: "x", b: 1 }, "a")).toBe("x");
    expect(files.textField({ a: "x", b: 1 }, "b")).toBe("");
    expect(files.stringRecord({ a: "x", b: 1, c: "y" })).toEqual({ a: "x", c: "y" });
    expect(files.stringRecord([1])).toEqual({});
    expect(files.orNull(undefined)).toBeNull();
    expect(files.orNull(0)).toBe(0);
    expect(new files.CodedError(69, "why")).toMatchObject({ code: 69, message: "why" });
  });
});

describe("layout", () => {
  it("derives every path from the state and data directories", () => {
    const result = boardPaths({ state: "/s", data: "/d" });
    expect(result).toEqual({
      runtimeDir: "/s/myshape",
      socket: "/s/myshape/board.sock",
      token: "/s/myshape/token",
      port: "/s/myshape/port",
      pid: "/s/myshape/pid",
      log: "/s/myshape/service.log",
      startupError: "/s/myshape/startup-error",
      audit: "/s/myshape/audit.jsonl",
      topics: "/d/topics.json",
      archive: "/d/topics-archive.json",
      dataDir: "/d",
      boardDataDir: "/d/myshape",
      events: "/d/myshape/events.jsonl",
      summaries: "/d/myshape/summaries.jsonl",
      notifyPending: "/d/myshape/notify-pending.json",
      aggregator: "/d/myshape/aggregator.json",
      todos: "/d/myshape/todos.json",
    });
  });

  it("parses the shared flags and returns what follows the separator", () => {
    const argv = [
      "--home",
      "/h",
      "--root",
      "/r",
      "--commit",
      "abc",
      "--port",
      "47819",
      "--state",
      "/s",
      "--data",
      "/d",
    ];
    expect(parseConfigArgs([...argv, "--", "move", "--first"])).toEqual({
      config: { home: "/h", root: "/r", commit: "abc", port: 47819, state: "/s", data: "/d" },
      rest: ["move", "--first"],
    });
    expect(parseConfigArgs(argv).rest).toEqual([]);
    expect(() => parseConfigArgs(argv.slice(2))).toThrow("missing --home");
    expect(() => parseConfigArgs(["--bogus", "x", ...argv])).toThrow(
      "unexpected argument: --bogus",
    );
    expect(() => parseConfigArgs(["stray", ...argv])).toThrow("unexpected argument: stray");
    expect(() => parseConfigArgs([...argv, "--home"])).toThrow("unexpected argument: --home");
    expect(() => parseConfigArgs([...argv.slice(0, 1), "", ...argv.slice(2)])).toThrow(
      "missing --home",
    );
    for (const port of ["0", "65536", "1.5", "x"]) {
      expect(() =>
        parseConfigArgs(argv.map((value) => (value === "47819" ? port : value))),
      ).toThrow("--port is not a port number");
    }
    expect(
      parseConfigArgs(argv.map((value) => (value === "47819" ? "65535" : value))).config.port,
    ).toBe(65535);
    expect(
      parseConfigArgs(argv.map((value) => (value === "47819" ? "1" : value))).config.port,
    ).toBe(1);
  });
});

function done(result: TopicResult): TopicState {
  if (!result.ok) throw new Error(result.line);
  return result.state;
}

describe("store", () => {
  it("loads an empty state when nothing is on disk", () => {
    expect(loadTopicState(paths)).toEqual({ state: emptyState(), confirmed: [] });
  });

  it("round-trips topics, queues, merges, and the archive", () => {
    let state = emptyState();
    state = done(create(state, { name: "A", goal: "ga", id: "a", queue: "high" }, "T"));
    state = done(create(state, { name: "B", goal: "gb", id: "b" }, "T"));
    state.doc.topics["a"]!.close_proposal = { at: "T2", reason: "done" };
    state.doc.merged = { old: "a" };
    state.doc.next_seq = 7;
    saveTopicState(paths, emptyState(), state);
    expect(loadTopicState(paths).state).toEqual(state);
    expect(fs.readFileSync(paths.topics, "utf8").endsWith("}\n")).toBe(true);
    expect(fs.existsSync(paths.archive)).toBe(false);

    const archived = done(archive(state, "a", "T3"));
    saveTopicState(paths, state, archived);
    expect(loadTopicState(paths).state).toEqual(archived);
    expect(mode(paths.topics)).toBe(0o644);
  });

  it("writes only the file that changed", () => {
    const state = done(create(emptyState(), { name: "A", goal: "g", id: "a" }, "T"));
    saveTopicState(paths, emptyState(), state);
    const before = fs.statSync(paths.topics).mtimeMs;
    saveTopicState(paths, state, state);
    expect(fs.statSync(paths.topics).mtimeMs).toBe(before);
    expect(fs.existsSync(paths.archive)).toBe(false);
  });

  it("writes the file that gains the topic first, so a crash never loses it", () => {
    const live = done(create(emptyState(), { name: "A", goal: "g", id: "a" }, "T"));
    const archived = done(archive(live, "a", "T2"));
    const block = (file: string): void => {
      fs.mkdirSync(file);
      fs.writeFileSync(path.join(file, "in-the-way"), "");
    };
    // Archiving: the archive must be on disk before the topic leaves topics.json.
    block(paths.topics);
    expect(() => saveTopicState(paths, live, archived)).toThrow();
    expect(JSON.parse(fs.readFileSync(paths.archive, "utf8")).topics.a.archived_at).toBe("T2");
    fs.rmSync(paths.topics, { recursive: true });
    fs.rmSync(paths.archive);
    // Reopening: topics.json must have the topic before it leaves the archive.
    block(paths.archive);
    expect(() => saveTopicState(paths, archived, live)).toThrow();
    expect(JSON.parse(fs.readFileSync(paths.topics, "utf8")).topics.a.status).toBe("confirmed");
  });

  it("keeps the live copy of a topic a crash left in both files", () => {
    const live = {
      v: 1,
      topics: { a: { name: "A", goal: "g", status: "confirmed" } },
      queues: { normal: ["a"] },
    };
    const gone = {
      v: 1,
      topics: {
        a: { name: "A", goal: "g", status: "confirmed", archived_at: "T" },
        z: { name: "Z", goal: "g", status: "confirmed" },
      },
    };
    fs.writeFileSync(paths.topics, JSON.stringify(live));
    fs.writeFileSync(paths.archive, JSON.stringify(gone));
    const { state } = loadTopicState(paths);
    expect(Object.keys(state.doc.topics)).toEqual(["a"]);
    expect(state.archive.topics).toEqual({
      z: {
        name: "Z",
        goal: "g",
        status: "confirmed",
        created_at: "",
        archived_at: "",
      },
    });
  });

  it("loads a file written before hands-on items existed, and drops marks it cannot read", () => {
    fs.mkdirSync(path.dirname(paths.topics), { recursive: true });
    const base = { v: 1, next_seq: 1, queues: {}, topics: {} };
    fs.writeFileSync(paths.topics, JSON.stringify(base));
    expect(loadTopicState(paths).state.doc.todos).toEqual({});
    const todos = {
      a: { state: "claimed", at: "2026-11-17T00:00:00Z" },
      b: { state: "rejected", at: "2026-11-17T00:00:00Z", reason: "沒起來" },
      c: { state: "unknown", at: "2026-11-17T00:00:00Z" },
      d: { state: "claimed" },
      e: "nope",
      ["__proto__"]: { state: "claimed", at: "2026-11-17T00:00:00Z" },
    };
    fs.writeFileSync(paths.topics, JSON.stringify({ ...base, todos }));
    expect(loadTopicState(paths).state.doc.todos).toEqual({ a: todos.a, b: todos.b });
    fs.writeFileSync(paths.topics, JSON.stringify({ ...base, todos: [1] }));
    expect(loadTopicState(paths).state.doc.todos).toEqual({});
  });

  it("loads a file written before the history existed, and drops history entries it cannot read", () => {
    fs.mkdirSync(path.dirname(paths.topics), { recursive: true });
    const base = { v: 1, next_seq: 1, topics: {}, queues: {}, merged: { old: "a" } };
    fs.writeFileSync(paths.topics, JSON.stringify(base));
    expect(loadTopicState(paths).state.doc.history).toEqual([]);
    const good = { at: "T", kind: "merged", topic: "a", name: "A", from: "old", from_name: "Old" };
    const history = [
      good,
      { at: "T", kind: "weird", topic: "a", name: "A" },
      { kind: "merged" },
      7,
    ];
    fs.writeFileSync(paths.topics, JSON.stringify({ ...base, history }));
    expect(loadTopicState(paths).state.doc.history).toEqual([good]);
    const told = { ...good, reason: "重複了", by: "page" };
    const odd = [
      { ...good, reason: 7, by: "someone" },
      { ...good, reason: "" },
      { ...good, reason: "two\nlines" },
      { ...good, reason: "x".repeat(201) },
    ];
    fs.writeFileSync(paths.topics, JSON.stringify({ ...base, history: [told, ...odd] }));
    expect(loadTopicState(paths).state.doc.history).toEqual([told, good, good, good, good]);
    fs.writeFileSync(paths.topics, JSON.stringify({ ...base, history: "nope" }));
    expect(loadTopicState(paths).state.doc.history).toEqual([]);
  });

  it("repairs what it can and fills defaults", () => {
    const raw = {
      v: 1,
      next_seq: 0,
      topics: {
        a: {
          name: "A",
          goal: "g",
          status: "confirmed",
          proposed_by: "user",
          suggested_queue: "high",
          close_proposal: { at: "T" },
        },
        p: { name: "P", goal: "g", status: "proposed", suggested_queue: "urgent", created_at: 5 },
      },
      queues: { high: ["a", "a", "p", "ghost", 3], normal: "no", later: [] },
      merged: { old: "a", bad: 3 },
    };
    fs.writeFileSync(paths.topics, JSON.stringify(raw));
    const { doc } = loadTopicState(paths).state;
    // A proposal listed in a queue by hand is not in it; it is confirmed like any other.
    expect(doc.queues).toEqual({ high: ["a"], normal: ["p"], later: [] });
    expect(doc.merged).toEqual({ old: "a" });
    expect(doc.next_seq).toBe(1);
    expect(doc.topics["a"]).toEqual({ name: "A", goal: "g", status: "confirmed", created_at: "" });
    expect(doc.topics["p"]).toEqual({ name: "P", goal: "g", status: "confirmed", created_at: "" });
    expect(fs.readFileSync(paths.topics, "utf8")).not.toContain("proposed");
    expect(fs.existsSync(paths.archive)).toBe(false);
    fs.writeFileSync(
      paths.topics,
      JSON.stringify({ ...raw, next_seq: 9, queues: undefined, merged: undefined }),
    );
    expect(loadTopicState(paths).state.doc).toMatchObject({
      next_seq: 9,
      queues: { high: [], normal: ["p"], later: [] },
      merged: {},
    });
    fs.writeFileSync(paths.topics, JSON.stringify({ ...raw, next_seq: 2.5 }));
    expect(loadTopicState(paths).state.doc.next_seq).toBe(1);
  });

  it("confirms leftover proposals at the end of the queue each was proposed for, once", () => {
    const raw = {
      v: 1,
      next_seq: 4,
      queues: { high: ["h"], normal: ["n1", "n2"], later: ["l"] },
      topics: {
        h: { name: "H", goal: "g", status: "confirmed", created_at: "2026-11-01T00:00:00Z" },
        n1: { name: "N1", goal: "g", status: "confirmed", created_at: "2026-11-01T00:00:00Z" },
        n2: { name: "N2", goal: "g", status: "confirmed", created_at: "2026-11-01T00:00:00Z" },
        l: { name: "L", goal: "g", status: "confirmed", created_at: "2026-11-01T00:00:00Z" },
        late: { name: "Late", goal: "g", status: "proposed", created_at: "2026-11-18T03:00:00Z" },
        early: { name: "Early", goal: "g", status: "proposed", created_at: "2026-11-18T01:00:00Z" },
        hot: {
          name: "Hot",
          goal: "g",
          status: "proposed",
          created_at: "2026-11-18T02:00:00Z",
          proposed_by: "an agent",
          suggested_queue: "high",
        },
      },
      merged: { old: "early" },
      history: [{ at: "T", kind: "renamed", topic: "early", name: "Early", from_name: "E" }],
      todos: { x: { state: "claimed", at: "T" } },
    };
    const gone = {
      v: 1,
      topics: {
        dropped: { name: "D", goal: "g", status: "proposed", archived_at: "T", created_at: "T0" },
      },
    };
    fs.writeFileSync(paths.topics, JSON.stringify(raw));
    fs.writeFileSync(paths.archive, JSON.stringify(gone));
    const first = loadTopicState(paths);
    expect(first.state.doc.queues).toEqual({
      high: ["h", "hot"],
      normal: ["n1", "n2", "early", "late"],
      later: ["l"],
    });
    expect(first.confirmed).toEqual([
      { id: "early", name: "Early", queue: "normal" },
      { id: "hot", name: "Hot", queue: "high" },
      { id: "late", name: "Late", queue: "normal" },
    ]);
    expect(first.state.doc.topics["hot"]).toEqual({
      name: "Hot",
      goal: "g",
      status: "confirmed",
      created_at: "2026-11-18T02:00:00Z",
    });
    expect(first.state.doc.merged).toEqual({ old: "early" });
    expect(first.state.doc.history).toHaveLength(1);
    expect(first.state.doc.todos).toEqual(raw.todos);
    expect(first.state.doc.next_seq).toBe(4);
    expect(first.state.archive.topics["dropped"]).toEqual({
      name: "D",
      goal: "g",
      status: "confirmed",
      created_at: "T0",
      archived_at: "T",
    });

    // Written back at once: the files no longer hold a proposal, so the next load confirms nothing.
    const onDisk = JSON.parse(fs.readFileSync(paths.topics, "utf8")) as { topics: object };
    expect(JSON.stringify(onDisk)).not.toContain("proposed");
    expect(fs.readFileSync(paths.archive, "utf8")).not.toContain("proposed");
    expect(onDisk).toEqual(first.state.doc);
    // A rewrite replaces the file, so an unchanged inode means it was left alone.
    const written = [fs.statSync(paths.topics).ino, fs.statSync(paths.archive).ino];
    const second = loadTopicState(paths);
    expect(second).toEqual({ state: first.state, confirmed: [] });
    expect([fs.statSync(paths.topics).ino, fs.statSync(paths.archive).ino]).toEqual(written);
  });

  it("orders leftover proposals made at the same moment by id", () => {
    const proposal = { goal: "g", status: "proposed", created_at: "2026-11-18T01:00:00Z" };
    const raw = {
      v: 1,
      queues: {},
      topics: {
        b: { ...proposal, name: "B" },
        c: { ...proposal, name: "C" },
        a: { ...proposal, name: "A" },
      },
    };
    fs.writeFileSync(paths.topics, JSON.stringify(raw));
    expect(loadTopicState(paths).state.doc.queues.normal).toEqual(["a", "b", "c"]);
  });

  it("rewrites only the archive when only the archive holds a proposal", () => {
    const live = {
      v: 1,
      queues: { normal: ["a"] },
      topics: { a: { name: "A", goal: "g", status: "confirmed" } },
    };
    fs.writeFileSync(paths.topics, JSON.stringify(live));
    const gone = {
      v: 1,
      topics: { d: { name: "D", goal: "g", status: "proposed", archived_at: "T" } },
    };
    fs.writeFileSync(paths.archive, JSON.stringify(gone));
    const loaded = loadTopicState(paths);
    expect(loaded.confirmed).toEqual([]);
    expect(fs.readFileSync(paths.topics, "utf8")).toBe(JSON.stringify(live));
    expect(fs.readFileSync(paths.archive, "utf8")).not.toContain("proposed");
    expect(loaded.state.archive.topics["d"]?.status).toBe("confirmed");
  });

  it("refuses a file it cannot understand, naming it", () => {
    const bad: unknown[] = [
      "not json",
      "[]",
      '{"v":2,"topics":{}}',
      '{"v":1}',
      '{"v":1,"topics":{"a":5}}',
      '{"v":1,"topics":{"a":{"name":"A","status":"confirmed"}}}',
      '{"v":1,"topics":{"a":{"name":"A","goal":"g","status":"odd"}}}',
    ];
    for (const text of bad) {
      fs.writeFileSync(paths.topics, text as string);
      expect(() => loadTopicState(paths)).toThrow(`${paths.topics} 讀不懂`);
    }
    fs.rmSync(paths.topics);
    for (const text of ["nope", '{"v":1}', '{"v":2,"topics":{}}', '{"v":1,"topics":[]}']) {
      fs.writeFileSync(paths.archive, text);
      expect(() => loadTopicState(paths)).toThrow(`${paths.archive} 讀不懂`);
    }
  });
});

describe("journal", () => {
  const line = (task: string, ts = 5) =>
    JSON.stringify({ v: 1, ts, event: "task.status", task, state: "working" });

  it("stores ledger lines once per home and reloads them", () => {
    const journal = new Journal(paths.events);
    expect(journal.appendLedger("main", [line("a"), line("b"), line("a")])).toBe(2);
    expect(journal.appendLedger("main", [line("a")])).toBe(0);
    expect(journal.appendLedger("sm", [line("a")])).toBe(1);
    expect(journal.events).toHaveLength(3);
    expect(journal.events[0]).toEqual({
      src: "ledger",
      home: "main",
      ts: 5,
      event: "task.status",
      task: "a",
      fields: JSON.parse(line("a")),
    });
    expect(fs.readFileSync(paths.events, "utf8").split("\n")[0]).toBe(
      JSON.stringify({ src: "ledger", home: "main", raw: line("a") }),
    );

    const reloaded = new Journal(paths.events);
    expect(reloaded.events).toEqual(journal.events);
    expect(reloaded.appendLedger("main", [line("b"), line("c")])).toBe(1);
  });

  it("remembers unreadable ledger lines without showing them", () => {
    const journal = new Journal(paths.events);
    const odd = [
      "not json",
      "[1]",
      JSON.stringify({ ts: 1, task: "t" }),
      JSON.stringify({ ts: 1, event: "e" }),
      JSON.stringify({ ts: "1", event: "e", task: "t" }),
    ];
    expect(journal.appendLedger("main", odd)).toBe(5);
    expect(journal.events).toEqual([]);
    expect(new Journal(paths.events).appendLedger("main", odd)).toBe(0);
    fs.appendFileSync(
      paths.events,
      `${JSON.stringify({ src: "ledger", home: "h" })}\n${JSON.stringify({ src: "ledger", raw: "r" })}\n`,
    );
    const reloaded = new Journal(paths.events);
    expect(reloaded.appendLedger("h", ["null"])).toBe(1);
    expect(reloaded.appendLedger("null", ["r"])).toBe(1);
  });

  it("stores board events and skips junk lines on reload", () => {
    const journal = new Journal(paths.events);
    journal.appendBoard({
      ts: 9,
      kind: "topic.confirmed",
      topic: "a",
      home: null,
      task: null,
      text: "confirmed",
    });
    fs.appendFileSync(
      paths.events,
      `junk\n[]\n${JSON.stringify({ src: "other" })}\n${JSON.stringify({ src: "board", kind: "k" })}\n${JSON.stringify({ src: "board", ts: 1 })}\n${JSON.stringify({ src: "ledger", home: "h" })}\n${JSON.stringify({ src: "ledger", raw: "r" })}\n${JSON.stringify({ src: "board", ts: 3, kind: "k" })}\n`,
    );
    expect(new Journal(paths.events).events).toEqual([
      {
        src: "board",
        ts: 9,
        kind: "topic.confirmed",
        topic: "a",
        home: null,
        task: null,
        text: "confirmed",
      },
      { src: "board", ts: 3, kind: "k", topic: null, home: null, task: null, text: "" },
    ]);
    expect(mode(paths.events)).toBe(0o644);
  });

  it("stores a summary once and reloads valid ones", () => {
    const summaries = new Summaries(paths.summaries);
    const summary = { ts: 1, home: "main", task: "t", kind: "ready" as const, text: "PR is up" };
    expect(summaries.add(summary)).toBe(true);
    expect(summaries.add({ ...summary, ts: 99 })).toBe(false);
    for (const change of [
      { home: "sm" },
      { task: "u" },
      { kind: "landed" as const },
      { text: "other" },
    ]) {
      expect(summaries.add({ ...summary, ...change })).toBe(true);
    }
    fs.appendFileSync(
      paths.summaries,
      `junk\n[]\n${JSON.stringify({ ...summary, kind: "odd" })}\n${JSON.stringify({ ...summary, ts: "1" })}\n${JSON.stringify({ ...summary, home: 1 })}\n${JSON.stringify({ ...summary, task: 1 })}\n${JSON.stringify({ ...summary, text: 1 })}\n`,
    );
    const reloaded = new Summaries(paths.summaries);
    expect(reloaded.all).toEqual(summaries.all);
    expect(reloaded.all).toHaveLength(5);
  });

  it("retracts the latest summary of a kind and lets the same text be stored again", () => {
    const summaries = new Summaries(paths.summaries);
    const landed = { ts: 5, home: "main", task: "t", kind: "landed" as const, text: "landed" };
    summaries.add({ ...landed, ts: 1, kind: "ready", text: "first PR" });
    summaries.add({ ...landed, ts: 2, kind: "ready", text: "second PR" });
    summaries.add(landed);
    summaries.add({ ...landed, task: "other" });
    const reason = { ts: 9, home: "main", task: "t", text: "the merge had failed" };
    expect(summaries.retract({ ...reason, kind: "landed" })).toEqual(landed);
    expect(summaries.retract({ ...reason, kind: "landed" })).toBeNull();
    expect(summaries.retract({ ...reason, kind: "failed" })).toBeNull();
    expect(summaries.retract({ ...reason, home: "sm", kind: "ready" })).toBeNull();
    const shown = (from: Summaries): string[] =>
      from.all.map((entry) => `${entry.task}:${entry.kind}:${entry.text}`);
    expect(shown(summaries)).toEqual([
      "t:ready:first PR",
      "t:ready:second PR",
      "other:landed:landed",
    ]);
    expect(summaries.retract({ ...reason, kind: "ready" })?.text).toBe("second PR");
    expect(shown(new Summaries(paths.summaries))).toEqual([
      "t:ready:first PR",
      "other:landed:landed",
    ]);
    expect(summaries.add({ ...landed, ts: 20 })).toBe(true);
    expect(shown(new Summaries(paths.summaries))).toEqual([
      "t:ready:first PR",
      "other:landed:landed",
      "t:landed:landed",
    ]);
  });

  it("keeps a ledger cursor per home across restarts", () => {
    const offsets = new Offsets(paths);
    expect(offsets.get("main")).toEqual({ offset: 0, sha: "-" });
    offsets.set("main", { offset: 12, sha: "abc" });
    offsets.set("sm", { offset: 3, sha: "def" });
    const cursorFile = path.join(paths.boardDataDir, "offsets.json");
    const written = fs.statSync(cursorFile).mtimeMs;
    const busyUntil = Date.now() + 20;
    while (Date.now() < busyUntil);
    offsets.set("sm", { offset: 3, sha: "def" });
    expect(fs.statSync(cursorFile).mtimeMs).toBe(written);
    offsets.set("sm", { offset: 3, sha: "moved" });
    offsets.set("sm", { offset: 4, sha: "moved" });
    expect(fs.statSync(cursorFile).mtimeMs).toBeGreaterThan(written);
    offsets.set("sm", { offset: 3, sha: "def" });
    const reloaded = new Offsets(paths);
    expect(reloaded.get("main")).toEqual({ offset: 12, sha: "abc" });
    expect(reloaded.get("sm")).toEqual({ offset: 3, sha: "def" });
    const file = path.join(paths.boardDataDir, "offsets.json");
    fs.writeFileSync(
      file,
      JSON.stringify({
        main: { offset: "1", sha: "x" },
        sm: { offset: 1 },
        ok: { offset: 4, sha: "s" },
        bad: 3,
      }),
    );
    const partial = new Offsets(paths);
    expect([partial.get("main"), partial.get("sm"), partial.get("ok"), partial.get("bad")]).toEqual(
      [
        { offset: 0, sha: "-" },
        { offset: 0, sha: "-" },
        { offset: 4, sha: "s" },
        { offset: 0, sha: "-" },
      ],
    );
    fs.writeFileSync(file, "not json");
    expect(new Offsets(paths).get("ok")).toEqual({ offset: 0, sha: "-" });
    fs.writeFileSync(file, "[]");
    expect(new Offsets(paths).get("ok")).toEqual({ offset: 0, sha: "-" });
  });
});
