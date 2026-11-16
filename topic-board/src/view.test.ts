import { describe, expect, it } from "vitest";
import type { JournalEvent, Summary } from "./journal.js";
import type { HomeReport, ReportHold } from "./report.js";
import { emptyState } from "./topics.js";
import type { TopicState } from "./topics.js";
import { buildView, parseOptions, parseTags, placeTask } from "./view.js";
import type { HomeSnapshot, ViewInput } from "./view.js";

const NOW = Date.parse("2026-07-10T00:00:00Z");
const T0 = Date.parse("2026-07-01T00:00:00Z") / 1000;

function topics(): TopicState {
  const state = emptyState();
  const topic = (name: string) => ({
    name,
    goal: `goal of ${name}`,
    status: "confirmed" as const,
    created_at: "",
    proposed_by: "firstmate" as const,
  });
  state.doc.topics = {
    hi: topic("High"),
    n1: { ...topic("Normal one"), close_proposal: { at: "x", reason: "all done" } },
    n2: topic("Normal two"),
    lt: topic("Later"),
    idea: { ...topic("Idea"), status: "proposed", suggested_queue: "high" },
  };
  state.doc.queues = { high: ["hi"], normal: ["n1", "n2"], later: ["lt"] };
  state.doc.merged = { old: "n1" };
  state.archive.topics = { gone: { ...topic("Gone"), archived_at: "2026-06-01T00:00:00Z" } };
  return state;
}

function hold(id: string, extra: Partial<ReportHold> = {}): ReportHold {
  return {
    id,
    title: `title ${id}`,
    question: "q",
    hold_bucket: "live",
    hold_until: null,
    unresolved_blocker_ids: [],
    hold_age_days: 1,
    origin: "",
    ...extra,
  };
}

function report(extra: Partial<HomeReport> = {}): HomeReport {
  return {
    code_commit: "c",
    ledger_enabled: true,
    tasks: [],
    holds: [],
    status_decisions: [],
    topics: {},
    ledger: { status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: [] },
    secondmates: [],
    ...extra,
  };
}

function home(id: string, extra: Partial<HomeSnapshot> = {}): HomeSnapshot {
  return {
    id,
    remote: false,
    report: report(),
    lastOkAt: NOW - 1000,
    error: null,
    version: "same",
    ...extra,
  };
}

function input(extra: Partial<ViewInput> = {}): ViewInput {
  return {
    topics: topics(),
    homes: [home("main")],
    events: [],
    summaries: [],
    nowMs: NOW,
    staleMs: 180_000,
    ...extra,
  };
}

const tag = (topic: string, day = "01") => `${topic} 2026-07-${day}T00:00:00Z`;

describe("parseTags and parseOptions", () => {
  it("reads one tag per line and tolerates blanks and bad times", () => {
    expect(parseTags("a 2026-07-01T00:00:00Z\n\nb not-a-time\nc\n")).toEqual([
      { topic: "a", atMs: T0 * 1000 },
      { topic: "b", atMs: 0 },
      { topic: "c", atMs: 0 },
    ]);
    expect(parseTags("")).toEqual([]);
  });

  it("takes the options after the last marker of the last line", () => {
    expect(parseOptions("要合併嗎？\n選項：合併 | 先不要")).toEqual(["合併", "先不要"]);
    expect(parseOptions("要合併嗎？ 選項：A | B | C\n")).toEqual(["A", "B", "C"]);
    expect(parseOptions("選項：X | Y 再說 選項： A  |  B ")).toEqual(["A", "B"]);
    expect(parseOptions("選項：A | B\n後面還有一行")).toEqual([]);
    expect(parseOptions("x選項：A | B")).toEqual(["A", "B"]);
    expect(parseOptions("選項：只有一個")).toEqual([]);
    expect(parseOptions("選項：A | ")).toEqual([]);
    expect(parseOptions("選項：A|B")).toEqual([]);
    expect(parseOptions("沒有選項")).toEqual([]);
    expect(parseOptions("")).toEqual([]);
  });
});

describe("placement", () => {
  const homes = [
    home("main", {
      report: report({
        topics: {
          a: tag("hi"),
          b: tag("old"),
          c: tag("idea"),
          d: tag("nope"),
          e: tag("gone"),
          f: `${tag("hi")}\n${tag("n2", "02")}`,
        },
      }),
    }),
  ];
  it("resolves a task's newest tag through merges to a usable topic", () => {
    const place = (task: string) => placeTask(topics(), homes, "main", task);
    expect(place("a")).toEqual({ topic: "hi", reason: null });
    expect(place("b")).toEqual({ topic: "n1", reason: null });
    expect(place("c")).toEqual({ topic: null, reason: "proposed" });
    expect(place("d")).toEqual({ topic: null, reason: "unknown-topic" });
    expect(place("e")).toEqual({ topic: "gone", reason: null });
    expect(place("f")).toEqual({ topic: "n2", reason: null });
    expect(place("untagged")).toEqual({ topic: null, reason: "no-tag" });
    const emptyFile = [home("main", { report: report({ topics: { g: "" } }) })];
    expect(placeTask(topics(), emptyFile, "main", "g")).toEqual({ topic: null, reason: "no-tag" });
    expect(placeTask(topics(), homes, "elsewhere", "a")).toEqual({ topic: null, reason: "no-tag" });
  });
});

describe("homes", () => {
  it("reports version, ledger flag, age, and staleness at the limit", () => {
    const view = buildView(
      input({
        homes: [
          home("main", { lastOkAt: NOW - 180_000 }),
          home("far", {
            remote: true,
            lastOkAt: NOW - 180_001,
            error: "ssh failed",
            version: "different",
            report: report({ ledger_enabled: false }),
          }),
          home("never", { lastOkAt: null, report: null, version: "not-on-fork" }),
        ],
      }),
    );
    expect(view.homes).toEqual([
      {
        id: "main",
        remote: false,
        version: "same",
        ledger_enabled: true,
        stale: false,
        last_ok_seconds_ago: 180,
        error: null,
      },
      {
        id: "far",
        remote: true,
        version: "different",
        ledger_enabled: false,
        stale: true,
        last_ok_seconds_ago: 180,
        error: "ssh failed",
      },
      {
        id: "never",
        remote: false,
        version: "not-on-fork",
        ledger_enabled: null,
        stale: true,
        last_ok_seconds_ago: null,
        error: null,
      },
    ]);
  });
});

describe("agents", () => {
  const task = (id: string, state: string, kind = "ship") => ({
    id,
    kind,
    state,
    source: "s",
    detail: `detail ${id}`,
    unstarted: false,
  });
  const ledger = (taskId: string, event: string, ts: number, homeId = "main"): JournalEvent => ({
    src: "ledger",
    home: homeId,
    ts,
    event,
    task: taskId,
    fields: {},
  });

  it("maps each state to a light and puts a live hold first", () => {
    const states = ["blocked", "failed", "working", "parked", "paused", "done", "unknown", "odd"];
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({
              tasks: [
                ...states.map((state) => task(`t-${state}`, state)),
                task("held", "working"),
                task("deferred", "working"),
                task("mate", "working", "secondmate"),
              ],
              holds: [hold("held"), hold("deferred", { hold_bucket: "aged" })],
              topics: { held: tag("hi") },
            }),
          }),
        ],
        events: [ledger("held", "task.status", T0 + 5), ledger("held", "task.status", T0 + 9)],
      }),
    );
    const lights = Object.fromEntries(view.agents.map((agent) => [agent.task, agent.light]));
    expect(lights).toEqual({
      "t-blocked": "stuck",
      "t-failed": "stuck",
      "t-working": "working",
      "t-parked": "working",
      "t-paused": "working",
      "t-done": "done",
      "t-unknown": "unknown",
      "t-odd": "unknown",
      held: "decide",
      deferred: "working",
    });
    expect(view.agents.find((agent) => agent.task === "held")).toEqual({
      home: "main",
      task: "held",
      kind: "ship",
      light: "decide",
      state: "working",
      detail: "detail held",
      topic: "hi",
      unsorted_reason: null,
      updated_at: T0 + 9,
      stale: false,
      unstarted: false,
    });
    expect(view.agents.find((agent) => agent.task === "t-done")).toMatchObject({
      topic: null,
      unsorted_reason: "no-tag",
      updated_at: null,
    });
  });

  it("marks a task whose harness never took its first turn, and no ended one", () => {
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({
              tasks: [{ ...task("quiet", "working"), unstarted: true }, task("spoke", "working")],
            }),
          }),
        ],
        events: [ledger("quiet", "task.dispatched", T0), ledger("gone", "task.merged", T0 + 1)],
      }),
    );
    expect(view.agents.map((agent) => `${agent.task}:${agent.unstarted}`).toSorted()).toEqual([
      "gone:false",
      "quiet:true",
      "spoke:false",
    ]);
  });

  it("lists a cleaned-up task from its last ledger event, per home", () => {
    const view = buildView(
      input({
        homes: [
          home("main", { report: report({ tasks: [task("alive", "working")] }) }),
          home("sm", { report: report() }),
          home("down", { report: null }),
        ],
        events: [
          ledger("alive", "task.merged", T0),
          ledger("merged", "task.dispatched", T0),
          ledger("merged", "task.merged", T0 + 1),
          ledger("cleaned", "task.cleaned_up", T0 + 2),
          ledger("lost", "task.status", T0 + 3),
          ledger("theirs", "task.cleaned_up", T0 + 4, "sm"),
          ledger("ghost", "task.cleaned_up", T0 + 5, "down"),
        ],
      }),
    );
    expect(
      view.agents.map(
        (agent) => `${agent.home}/${agent.task}=${agent.light}:${agent.state}:${agent.kind}`,
      ),
    ).toEqual([
      "main/alive=working:working:ship",
      "main/merged=done:done:",
      "main/cleaned=done:done:",
      "main/lost=unknown:unknown:",
      "sm/theirs=done:done:",
    ]);
  });

  it("turns every light of a stale home to unknown but keeps the state text", () => {
    const view = buildView(
      input({
        homes: [
          home("main", {
            lastOkAt: NOW - 200_000,
            report: report({ tasks: [task("t", "working")], holds: [hold("t")] }),
          }),
        ],
      }),
    );
    expect(view.agents[0]).toMatchObject({ light: "unknown", state: "working", stale: true });
    expect(view.holds[0]?.stale).toBe(true);
  });
});

describe("holds and questions", () => {
  it("places a hold by its task, then its origin, and orders them", () => {
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({
              holds: [
                hold("loose"),
                hold("loose-old", { hold_age_days: 5 }),
                hold("own-wins", { origin: "worker" }),
                hold("age-unknown", { hold_age_days: null }),
                hold("via-origin", { origin: "worker" }),
                hold("origin-unknown", { origin: "nobody" }),
                hold("later-old", { hold_age_days: 9 }),
                hold("later-new", { hold_age_days: 2 }),
                hold("normal-2"),
                hold("normal-1", { question: "行嗎？ 選項：行 | 不行" }),
                hold("high-deferred", { hold_bucket: "dated", hold_until: "2026-12-01" }),
                hold("aged", { hold_bucket: "aged" }),
                hold("blocked", { hold_bucket: "blocked", unresolved_blocker_ids: ["x", "y"] }),
                hold("undated", { hold_bucket: "dated" }),
                hold("archived"),
              ],
              status_decisions: [
                { id: "worker", key: "k", summary: "which API?" },
                { id: "stranger", key: "", summary: "?" },
              ],
              topics: {
                worker: tag("hi"),
                "later-old": tag("lt"),
                "later-new": tag("lt"),
                "normal-2": tag("n2"),
                "own-wins": tag("n2"),
                "age-unknown": tag("n2"),
                "normal-1": tag("n1"),
                "high-deferred": tag("hi"),
                archived: tag("gone"),
              },
            }),
          }),
        ],
      }),
    );
    expect(view.holds.map((entry) => entry.task)).toEqual([
      "via-origin",
      "normal-1",
      "normal-2",
      "own-wins",
      "age-unknown",
      "later-old",
      "later-new",
      "loose-old",
      "archived",
      "loose",
      "origin-unknown",
      "high-deferred",
      "aged",
      "blocked",
      "undated",
    ]);
    const byTask = Object.fromEntries(view.holds.map((entry) => [entry.task, entry]));
    expect(byTask["via-origin"]).toEqual({
      home: "main",
      task: "via-origin",
      title: "title via-origin",
      question: "q",
      options: [],
      live: true,
      deferred_reason: null,
      topic: "hi",
      stale: false,
    });
    expect(byTask["normal-1"]?.options).toEqual(["行", "不行"]);
    expect(byTask["loose"]?.topic).toBeNull();
    expect(byTask["own-wins"]?.topic).toBe("n2");
    expect(byTask["origin-unknown"]?.topic).toBeNull();
    expect(byTask["archived"]?.topic).toBe("gone");
    expect(byTask["high-deferred"]).toMatchObject({
      live: false,
      deferred_reason: "延到 2026-12-01",
      topic: "hi",
    });
    expect(byTask["aged"]?.deferred_reason).toBe("已放超過 14 天");
    expect(byTask["blocked"]?.deferred_reason).toBe("等 x、y 完成");
    expect(byTask["undated"]?.deferred_reason).toBe("延到 之後");
    expect(view.questions).toEqual([
      { home: "main", task: "worker", key: "k", summary: "which API?", topic: "hi" },
      { home: "main", task: "stranger", key: "", summary: "?", topic: null },
    ]);
  });

  it("breaks ties between holds of one topic by task id", () => {
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({
              holds: [hold("b"), hold("a")],
              topics: { a: tag("hi"), b: tag("hi") },
            }),
          }),
        ],
      }),
    );
    expect(view.holds.map((entry) => entry.task)).toEqual(["a", "b"]);
  });
});

describe("updates and summaries", () => {
  const ledger = (
    taskId: string,
    event: string,
    ts: number,
    fields: Record<string, unknown> = {},
  ): JournalEvent => ({ src: "ledger", home: "main", ts, event, task: taskId, fields });
  const homes = [
    home("main", {
      report: report({
        topics: {
          t: `${tag("hi", "02")}\n${tag("n2", "04")}`,
          u: tag("old"),
          w: `${tag("hi", "02")}\n${tag("n2", "03")}\n${tag("lt", "04")}`,
        },
      }),
    }),
  ];
  const day = (n: number) => T0 + (n - 1) * 86_400;

  it("files each event under the topic tagged when it happened, newest first", () => {
    const events: JournalEvent[] = [
      ledger("t", "task.dispatched", day(1)),
      ledger("t", "task.status", day(2), { state: "working", text: " halfway " }),
      ledger("t", "task.status", day(3), { state: null, text: "no state" }),
      ledger("t", "task.pr_ready", day(4), { pr: "https://x/pull/1" }),
      ledger("t", "task.status", day(5), { state: "done" }),
      ledger("nobody", "task.cleaned_up", day(6), { pr: 7 }),
      ledger("w", "task.status", day(6) + 1),
      {
        src: "board",
        ts: day(7),
        kind: "topic.merged",
        topic: "old",
        home: null,
        task: null,
        text: "merged",
      },
      {
        src: "board",
        ts: day(8),
        kind: "hold.answered",
        topic: null,
        home: "main",
        task: "t",
        text: "answered",
      },
    ];
    const view = buildView(input({ homes, events }));
    expect(view.updates.map((update) => `${update.event}@${update.topic}`)).toEqual([
      "hold.answered@null",
      "topic.merged@n1",
      "task.status@lt",
      "task.cleaned_up@null",
      "task.status@n2",
      "task.pr_ready@n2",
      "task.status@hi",
      "task.status@hi",
      "task.dispatched@hi",
    ]);
    expect(view.updates[5]).toEqual({
      ts: day(4),
      source: "ledger",
      home: "main",
      task: "t",
      event: "task.pr_ready",
      text: "",
      pr: "https://x/pull/1",
      topic: "n2",
    });
    expect(view.updates[7]?.text).toBe("working：halfway");
    expect(view.updates[6]?.text).toBe("no state");
    expect(view.updates[4]?.text).toBe("done：");
    expect(view.updates[3]?.pr).toBeNull();
    expect(view.updates[1]).toEqual({
      ts: day(7),
      source: "board",
      home: null,
      task: null,
      event: "topic.merged",
      text: "merged",
      pr: null,
      topic: "n1",
    });
  });

  it("uses the one tag written by then even when it is not the file's first line", () => {
    const outOfOrder = [
      home("main", { report: report({ topics: { z: `${tag("n2", "04")}\n${tag("hi", "02")}` } }) }),
    ];
    const view = buildView(
      input({ homes: outOfOrder, events: [ledger("z", "task.status", day(3))] }),
    );
    expect(view.updates[0]?.topic).toBe("hi");
  });

  it("keeps only the newest 2000 updates", () => {
    const events = Array.from({ length: 2005 }, (_unused, index) =>
      ledger("t", "task.status", T0 + index),
    );
    const view = buildView(input({ homes, events }));
    expect(view.updates).toHaveLength(2000);
    expect(view.updates[0]?.ts).toBe(T0 + 2004);
    expect(view.updates.at(-1)?.ts).toBe(T0 + 5);
  });

  it("links a ready or landed summary to the task's latest PR at that time", () => {
    const events: JournalEvent[] = [
      ledger("t", "task.pr_ready", day(2), { pr: "https://x/pull/1" }),
      ledger("other", "task.pr_ready", day(3), { pr: "https://x/pull/9" }),
      ledger("t", "task.status", day(3), { pr: "https://x/not-a-pr-event" }),
      ledger("t", "task.merged", day(5), { pr: "https://x/pull/2" }),
      {
        src: "ledger",
        home: "sm",
        ts: day(2),
        event: "task.pr_ready",
        task: "t",
        fields: { pr: "https://x/pull/8" },
      },
    ];
    const summary = (kind: Summary["kind"], ts: number, taskId = "t"): Summary => ({
      ts,
      home: "main",
      task: taskId,
      kind,
      text: `${kind} text`,
    });
    const view = buildView(
      input({
        homes,
        events,
        summaries: [
          summary("ready", day(1)),
          summary("ready", day(2)),
          summary("ready", day(4)),
          summary("landed", day(6)),
          summary("report", day(6)),
          summary("failed", day(6), "u"),
        ],
      }),
    );
    expect(
      view.summaries.map((entry) => `${entry.kind}@${entry.ts - T0}:${entry.pr}:${entry.topic}`),
    ).toEqual([
      `landed@${5 * 86_400}:https://x/pull/2:n2`,
      `report@${5 * 86_400}:null:n2`,
      `failed@${5 * 86_400}:null:n1`,
      `ready@${3 * 86_400}:https://x/pull/1:n2`,
      `ready@${86_400}:https://x/pull/1:n2`,
      "ready@0:null:n2",
    ]);
    expect(view.summaries[0]).toEqual({
      ts: day(6),
      home: "main",
      task: "t",
      kind: "landed",
      text: "landed text",
      pr: "https://x/pull/2",
      topic: "n2",
    });
  });
});

describe("topics", () => {
  it("carries queues and every topic with its status", () => {
    const view = buildView(input());
    expect(view.queues).toEqual({ high: ["hi"], normal: ["n1", "n2"], later: ["lt"] });
    expect(view.topics["n1"]).toEqual({
      name: "Normal one",
      goal: "goal of Normal one",
      status: "confirmed",
      queue: "normal",
      suggested_queue: null,
      close_reason: "all done",
      archived_at: null,
    });
    expect(view.topics["hi"]).toMatchObject({ queue: "high", close_reason: null });
    expect(view.topics["lt"]?.queue).toBe("later");
    expect(view.topics["idea"]).toEqual({
      name: "Idea",
      goal: "goal of Idea",
      status: "proposed",
      queue: null,
      suggested_queue: "high",
      close_reason: null,
      archived_at: null,
    });
    expect(view.topics["gone"]).toEqual({
      name: "Gone",
      goal: "goal of Gone",
      status: "archived",
      queue: null,
      suggested_queue: null,
      close_reason: null,
      archived_at: "2026-06-01T00:00:00Z",
    });
  });

  it("does not share its queues with the topic state", () => {
    const state = topics();
    const view = buildView(input({ topics: state }));
    view.queues.high.push("x");
    expect(state.doc.queues.high).toEqual(["hi"]);
  });
});
