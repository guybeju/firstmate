import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AllowedCommand, CommandResult } from "./commands.js";
import { Journal, Offsets } from "./journal.js";
import { boardPaths } from "./layout.js";
import { DEFAULT_TIMINGS, Poller } from "./poller.js";
import type { PollTimings } from "./poller.js";

const LINE = (task: string) => JSON.stringify({ v: 1, ts: 5, event: "task.status", task });
const TIMINGS: PollTimings = {
  localMs: 40,
  remoteMs: 40,
  idleMs: 600,
  staleMs: 1000,
  localTimeoutMs: 111,
  remoteTimeoutMs: 222,
};

interface Setup {
  poller: Poller;
  journal: Journal;
  offsets: Offsets;
  calls: { command: AllowedCommand; known: string[]; timeout: number }[];
  /** What each home answers next; a function is called with the command. */
  answers: Map<string, (command: AllowedCommand) => CommandResult | Promise<CommandResult>>;
  changes: () => number;
}

let dir: string;
let pollers: Poller[];

function report(extra: Record<string, unknown> = {}): CommandResult {
  const body = {
    schema: 1,
    code_commit: "c1",
    ledger_enabled: true,
    tasks: [],
    holds: [],
    status_decisions: [],
    topics: {},
    ledger: { status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: [] },
    secondmates: [],
    ...extra,
  };
  return { code: 0, stdout: JSON.stringify(body), stderr: "" };
}

const SECONDMATES = [
  { id: "sm1", remote: false, home: "/h/sm1" },
  { id: "far1", remote: true, home: "/h/far1" },
];

function setup(timings: PollTimings = TIMINGS): Setup {
  const paths = boardPaths({ state: path.join(dir, "state"), data: path.join(dir, "data") });
  fs.mkdirSync(paths.boardDataDir, { recursive: true });
  const journal = new Journal(paths.events);
  const offsets = new Offsets(paths);
  const calls: Setup["calls"] = [];
  const answers: Setup["answers"] = new Map();
  let changes = 0;
  const poller = new Poller(
    async (command, known, timeout) => {
      calls.push({ command, known: known.map((entry) => entry.id), timeout });
      const home =
        command.kind === "read-main"
          ? "main"
          : "secondmate" in command
            ? (command.secondmate as string)
            : "main";
      const answer = answers.get(home);
      return answer === undefined ? report() : answer(command);
    },
    journal,
    offsets,
    timings,
    () => {
      changes += 1;
    },
  );
  pollers.push(poller);
  return { poller, journal, offsets, calls, answers, changes: () => changes };
}

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-poller-"));
  pollers = [];
});
afterEach(() => {
  for (const poller of pollers) poller.stop();
  fs.rmSync(dir, { recursive: true, force: true });
});

describe("reading the main home", () => {
  it("starts knowing only the main home, unread", () => {
    const { poller } = setup();
    expect(poller.snapshots()).toEqual([
      { id: "main", remote: false, report: null, lastOkAt: null, error: null, version: "unknown" },
    ]);
    expect(poller.secondmates()).toEqual([]);
    expect(poller.hasMainReport()).toBe(false);
    expect(poller.knows("main")).toBe(true);
    expect(poller.knows("sm1")).toBe(false);
    expect(poller.active).toBe(false);
    expect(DEFAULT_TIMINGS).toEqual({
      localMs: 10_000,
      remoteMs: 60_000,
      idleMs: 120_000,
      staleMs: 180_000,
      localTimeoutMs: 60_000,
      remoteTimeoutMs: 400_000,
    });
  });

  it("stores the report and learns the secondmates", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    const before = Date.now();
    expect(await s.poller.readNow("main")).toBe(true);
    const [main] = s.poller.snapshots();
    expect(main).toMatchObject({ id: "main", error: null, version: "same" });
    expect(main?.lastOkAt).toBeGreaterThanOrEqual(before);
    expect(s.poller.hasMainReport()).toBe(true);
    expect(s.poller.secondmates()).toEqual(SECONDMATES);
    expect(s.poller.knows("far1")).toBe(true);
    expect(s.calls[0]).toEqual({
      command: { kind: "read-main", offset: 0, sha: "-" },
      known: [],
      timeout: 111,
    });
    expect(s.changes()).toBe(1);
    expect(await s.poller.readNow("nobody")).toBe(false);
  });

  it("follows registry changes: new, moved, and removed secondmates", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    await s.poller.readNow("main");
    await s.poller.readNow("sm1");
    s.answers.set("main", () =>
      report({
        secondmates: [
          { id: "sm1", remote: true, home: "/moved" },
          { id: "new", remote: false, home: "/n" },
        ],
      }),
    );
    await s.poller.readNow("main");
    expect(s.poller.secondmates()).toEqual([
      { id: "sm1", remote: true, home: "/moved" },
      { id: "new", remote: false, home: "/n" },
    ]);
    expect(s.poller.knows("far1")).toBe(false);
    expect(s.poller.snapshots().find((home) => home.id === "sm1")?.report).not.toBeNull();
  });

  it("reads each home with its own command, cursor, and timeout", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    await s.poller.readNow("main");
    s.offsets.set("sm1", { offset: 7, sha: "a".repeat(64) });
    await s.poller.readNow("sm1");
    await s.poller.readNow("far1");
    expect(s.calls.slice(1)).toEqual([
      {
        command: { kind: "read-local", secondmate: "sm1", offset: 7, sha: "a".repeat(64) },
        known: ["sm1", "far1"],
        timeout: 111,
      },
      {
        command: { kind: "read-remote", secondmate: "far1", offset: 0, sha: "-" },
        known: ["sm1", "far1"],
        timeout: 222,
      },
    ]);
  });
});

describe("versions", () => {
  it("compares each home's commit with the main home's", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    s.answers.set("far1", () => report({ code_commit: "other" }));
    await s.poller.refreshAll();
    const versions = (): string =>
      s.poller
        .snapshots()
        .map((home) => `${home.id}:${home.version}`)
        .join(" ");
    expect(versions()).toBe("main:same sm1:same far1:different");
    s.answers.set("main", () => report({ secondmates: SECONDMATES, code_commit: "other" }));
    await s.poller.readNow("main");
    expect(versions()).toBe("main:same sm1:different far1:same");
    s.answers.set("main", () => report({ secondmates: SECONDMATES, code_commit: "" }));
    await s.poller.readNow("main");
    expect(versions()).toBe("main:same sm1:unknown far1:unknown");
  });

  it("reads the main home first on a full refresh, then every other home", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    await s.poller.refreshAll();
    expect(s.calls.map((call) => call.command.kind)).toEqual([
      "read-main",
      "read-local",
      "read-remote",
    ]);
  });
});

describe("the ledger", () => {
  const delta = (lines: string[], extra: Record<string, unknown> = {}) =>
    report({
      ledger: {
        status: "delta",
        to_offset: 10,
        to_prefix_sha256: "s1",
        more: false,
        lines,
        ...extra,
      },
    });

  it("stores new lines, then the cursor", async () => {
    const s = setup();
    s.answers.set("main", () => delta([LINE("a"), LINE("b")]));
    await s.poller.readNow("main");
    expect(
      s.journal.events.map((event) =>
        event.src === "ledger" ? `${event.home}/${event.task}` : "",
      ),
    ).toEqual(["main/a", "main/b"]);
    expect(s.offsets.get("main")).toEqual({ offset: 10, sha: "s1" });
    s.answers.set("main", () => delta([]));
    await s.poller.readNow("main");
    expect(s.offsets.get("main")).toEqual({ offset: 10, sha: "s1" });
  });

  it("keeps reading while the home says there is more", async () => {
    const s = setup();
    const pieces = [
      delta([LINE("a")], { more: true, to_offset: 5 }),
      delta([LINE("b")], { more: true, to_offset: 9 }),
      delta([LINE("c")], { to_offset: 12 }),
    ];
    s.answers.set("main", () => pieces.shift() as CommandResult);
    await s.poller.readNow("main");
    expect(
      s.calls.map((call) => (call.command.kind === "read-main" ? call.command.offset : -1)),
    ).toEqual([0, 5, 9]);
    expect(s.journal.events).toHaveLength(3);
    expect(s.changes()).toBe(1);
  });

  it("stops after 50 reads of a home that always has more", async () => {
    const s = setup();
    s.answers.set("main", () => delta([], { more: true }));
    await s.poller.readNow("main");
    expect(s.calls).toHaveLength(50);
  });

  it("rewinds and re-reads after a rewritten ledger without duplicating events", async () => {
    const s = setup();
    s.answers.set("main", () => delta([LINE("a")]));
    await s.poller.readNow("main");
    const answers = [
      report({
        ledger: {
          status: "continuity-broken",
          to_offset: 0,
          to_prefix_sha256: "-",
          more: false,
          lines: [],
        },
      }),
      delta([LINE("a"), LINE("z")], { to_offset: 20, to_prefix_sha256: "s2" }),
    ];
    s.answers.set("main", () => answers.shift() as CommandResult);
    await s.poller.readNow("main");
    expect(
      s.calls.map((call) =>
        call.command.kind === "read-main" ? `${call.command.offset}:${call.command.sha}` : "",
      ),
    ).toEqual(["0:-", "10:s1", "0:-"]);
    expect(s.journal.events).toHaveLength(2);
    expect(s.offsets.get("main")).toEqual({ offset: 20, sha: "s2" });
  });
});

describe("failures", () => {
  it("keeps the last report and records the error of a failed read", async () => {
    const s = setup();
    await s.poller.readNow("main");
    s.answers.set("main", () => ({ code: 1, stdout: "", stderr: `  ${"e".repeat(500)}  ` }));
    expect(await s.poller.readNow("main")).toBe(false);
    const [main] = s.poller.snapshots();
    expect(main?.report).not.toBeNull();
    expect(main?.error).toBe("e".repeat(400));
    expect(main?.version).toBe("same");
    s.answers.set("main", () => ({ code: null, stdout: "", stderr: "" }));
    await s.poller.readNow("main");
    expect(s.poller.snapshots()[0]?.error).toBe("讀取失敗");
    s.answers.delete("main");
    expect(await s.poller.readNow("main")).toBe(true);
    expect(s.poller.snapshots()[0]?.error).toBeNull();
  });

  it("marks a remote home without the script as not on the fork, and nothing else", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    await s.poller.refreshAll();
    const refusal = (text: string): CommandResult => ({
      code: 1,
      stdout: "",
      stderr: `fm-on: ${text}`,
    });
    for (const text of [
      "command is not tracked by the configured remote root",
      "command is not a genuine executable in the configured remote root",
    ]) {
      s.answers.set("far1", () => refusal(text));
      s.answers.set("sm1", () => refusal(text));
      s.answers.set("main", () => refusal(text));
      await s.poller.refreshAll();
      const state = Object.fromEntries(
        s.poller.snapshots().map((home) => [home.id, `${home.version}:${home.report === null}`]),
      );
      expect(state).toEqual({ main: "same:false", sm1: "same:false", far1: "not-on-fork:true" });
      s.answers.clear();
      s.answers.set("main", () => report({ secondmates: SECONDMATES }));
      await s.poller.refreshAll();
      expect(s.poller.snapshots().find((home) => home.id === "far1")).toMatchObject({
        version: "same",
        error: null,
      });
    }
    s.answers.set("far1", () => ({ code: 255, stdout: "", stderr: "ssh: connection refused" }));
    await s.poller.readNow("far1");
    expect(s.poller.snapshots().find((home) => home.id === "far1")).toMatchObject({
      version: "same",
      error: "ssh: connection refused",
    });
  });

  it("does not use output of another schema or output that is not a report", async () => {
    const s = setup();
    await s.poller.readNow("main");
    s.answers.set("main", () => report({ schema: 2, secondmates: SECONDMATES }));
    const callsBefore = s.calls.length;
    expect(await s.poller.readNow("main")).toBe(false);
    expect(s.calls).toHaveLength(callsBefore + 1);
    expect(s.poller.snapshots()[0]).toMatchObject({
      report: null,
      version: "incompatible",
      error: "彙整腳本的輸出版本和看板不相容",
    });
    s.answers.set("main", () => report());
    await s.poller.readNow("main");
    s.answers.set("main", () => ({ code: 0, stdout: "not json", stderr: "" }));
    const callsBeforeInvalid = s.calls.length;
    expect(await s.poller.readNow("main")).toBe(false);
    expect(s.calls).toHaveLength(callsBeforeInvalid + 1);
    const [main] = s.poller.snapshots();
    expect(main).toMatchObject({ version: "same", error: "彙整腳本的輸出不是合法的 JSON" });
    expect(main?.report).not.toBeNull();
  });
});

describe("a main home that stops being usable", () => {
  it("leaves other homes' versions unknown instead of failing", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    await s.poller.refreshAll();
    s.answers.set("main", () => report({ schema: 2 }));
    await s.poller.readNow("main");
    expect(await s.poller.readNow("sm1")).toBe(true);
    expect(s.poller.snapshots().find((home) => home.id === "sm1")?.version).toBe("unknown");
    expect(s.poller.hasMainReport()).toBe(false);
  });
});

describe("change notices", () => {
  it("reports a change only when something a viewer sees changed", async () => {
    const s = setup();
    await s.poller.readNow("main");
    await s.poller.readNow("main");
    await s.poller.readNow("main");
    expect(s.changes()).toBe(1);
    s.answers.set("main", () => report({ tasks: [{ id: "t", kind: "ship", state: "working" }] }));
    await s.poller.readNow("main");
    expect(s.changes()).toBe(2);
    s.answers.set("main", () => ({ code: 1, stdout: "", stderr: "boom" }));
    await s.poller.readNow("main");
    await s.poller.readNow("main");
    expect(s.changes()).toBe(3);
    s.answers.set("main", () =>
      report({
        tasks: [{ id: "t", kind: "ship", state: "working" }],
        ledger: {
          status: "delta",
          to_offset: 3,
          to_prefix_sha256: "s",
          more: false,
          lines: [LINE("t")],
        },
      }),
    );
    await s.poller.readNow("main");
    expect(s.changes()).toBe(4);
    s.answers.set("main", () =>
      report({
        tasks: [{ id: "t", kind: "ship", state: "working" }],
        ledger: {
          status: "delta",
          to_offset: 9,
          to_prefix_sha256: "s9",
          more: false,
          lines: [LINE("t")],
        },
      }),
    );
    await s.poller.readNow("main");
    expect(s.changes()).toBe(4);
  });
});

describe("scheduling", () => {
  it("joins a read in flight, and readFresh starts a new one after it", async () => {
    const s = setup();
    let release: (result: CommandResult) => void = () => undefined;
    s.answers.set("main", () => new Promise<CommandResult>((resolve) => (release = resolve)));
    const first = s.poller.readNow("main");
    const joined = s.poller.readNow("main");
    const fresh = s.poller.readFresh("main");
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(s.calls).toHaveLength(1);
    s.answers.set("main", () => report());
    release({ code: 1, stdout: "", stderr: "old read failed" });
    expect(await first).toBe(false);
    expect(await joined).toBe(false);
    expect(await fresh).toBe(true);
    expect(s.calls).toHaveLength(2);
    expect(await s.poller.readFresh("nobody")).toBe(false);
  });

  it("polls every home on its interval while someone is viewing, then stops", async () => {
    const s = setup();
    s.answers.set("main", () => report({ secondmates: SECONDMATES }));
    s.poller.touch();
    expect(s.poller.active).toBe(true);
    await vi.waitFor(() => expect(new Set(s.calls.map((call) => call.command.kind)).size).toBe(3), {
      timeout: 2000,
    });
    const early = s.calls.filter((call) => call.command.kind === "read-main").length;
    expect(early).toBeLessThanOrEqual(3);
    await new Promise((resolve) => setTimeout(resolve, 1000));
    expect(s.poller.active).toBe(false);
    const settled = s.calls.length;
    expect(s.calls.filter((call) => call.command.kind === "read-main").length).toBeGreaterThan(1);
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(s.calls).toHaveLength(settled);
    s.poller.touch();
    await vi.waitFor(() => expect(s.calls.length).toBeGreaterThan(settled), { timeout: 2000 });
  });

  it("never reads one home twice at once", async () => {
    const s = setup({ ...TIMINGS, localMs: 1, idleMs: 900 });
    let running = 0;
    let peak = 0;
    s.answers.set("main", async () => {
      running += 1;
      peak = Math.max(peak, running);
      await new Promise((resolve) => setTimeout(resolve, 60));
      running -= 1;
      return report();
    });
    s.poller.touch();
    await new Promise((resolve) => setTimeout(resolve, 800));
    s.poller.stop();
    expect(peak).toBe(1);
    expect(s.calls.length).toBeGreaterThan(1);
  });

  it("waits a whole interval between two reads of a home", async () => {
    const s = setup({ ...TIMINGS, localMs: 5000, idleMs: 900 });
    s.poller.touch();
    await new Promise((resolve) => setTimeout(resolve, 800));
    expect(s.calls).toHaveLength(1);
  });

  it("is active until exactly the idle limit after the last viewer", () => {
    const s = setup();
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      vi.setSystemTime(1_000_000);
      s.poller.touch();
      s.poller.stop();
      vi.setSystemTime(1_000_000 + TIMINGS.idleMs - 1);
      expect(s.poller.active).toBe(true);
      vi.setSystemTime(1_000_000 + TIMINGS.idleMs);
      expect(s.poller.active).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops polling on stop", async () => {
    const s = setup();
    s.poller.touch();
    s.poller.stop();
    await new Promise((resolve) => setTimeout(resolve, 450));
    expect(s.calls).toHaveLength(0);
  });
});
