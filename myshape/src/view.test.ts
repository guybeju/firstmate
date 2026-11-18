import { describe, expect, it } from "vitest";
import type { JournalEvent, Summary } from "./journal.js";
import type { HomeReport, ReportHold, ReportQueued } from "./report.js";
import { emptyState } from "./topics.js";
import type { TopicState } from "./topics.js";
import { buildView, parseOptions, parseTags, parseTodo, placeTask } from "./view.js";
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
  });
  state.doc.topics = {
    hi: topic("High"),
    n1: { ...topic("Normal one"), close_proposal: { at: "x", reason: "all done" } },
    n2: topic("Normal two"),
    lt: topic("Later"),
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
    on_answer: null,
    ...extra,
  };
}

function report(extra: Partial<HomeReport> = {}): HomeReport {
  return {
    queued: [],
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

describe("queued", () => {
  const item = (id: string, extra: Partial<ReportQueued> = {}): ReportQueued => ({
    id,
    kind: "ship",
    title: `title ${id}`,
    hold: null,
    captain: false,
    blockers: [],
    topic_hint: null,
    ...extra,
  });

  it("places an untagged queued item by the topic its body names, until a tag says otherwise", () => {
    const view = buildView(
      input({
        homes: [
          home("main"),
          home("sm1", {
            report: report({
              queued: [
                item("handed", { topic_hint: "hi" }),
                item("merged-hint", { topic_hint: "old" }),
                item("tagged", { topic_hint: "hi" }),
                item("unknown-hint", { topic_hint: "nope" }),
                item("bare"),
              ],
              topics: { tagged: "n2 2026-07-01T00:00:00Z" },
            }),
          }),
        ],
      }),
    );
    expect(Object.fromEntries(view.queued.map((entry) => [entry.task, entry.topic]))).toEqual({
      handed: "hi",
      "merged-hint": "n1",
      tagged: "n2",
      "unknown-hint": null,
      bare: null,
    });
  });

  it("lists every home's queued items under their topics with what each waits for", () => {
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({
              queued: [
                item("ready"),
                item("held", { hold: "waiting for a vendor" }),
                item("call", { kind: "captain", hold: "pick one", captain: true }),
                item("after", { blockers: ["ready", "held"] }),
                item("loose"),
                item("merged-away"),
              ],
              topics: {
                ready: "hi 2026-07-01T00:00:00Z",
                held: "hi 2026-07-01T00:00:00Z",
                call: "n1 2026-07-01T00:00:00Z",
                after: "lt 2026-07-01T00:00:00Z",
                "merged-away": "old 2026-07-01T00:00:00Z",
              },
            }),
          }),
          home("sm1", {
            report: report({ queued: [item("far")], topics: { far: "hi 2026-07-01T00:00:00Z" } }),
          }),
          home("down", { report: null }),
        ],
      }),
    );
    expect(view.queued).toEqual([
      {
        home: "main",
        task: "ready",
        kind: "ship",
        title: "title ready",
        topic: "hi",
        waiting: null,
      },
      {
        home: "main",
        task: "held",
        kind: "ship",
        title: "title held",
        topic: "hi",
        waiting: "停著：waiting for a vendor",
      },
      {
        home: "main",
        task: "call",
        kind: "captain",
        title: "title call",
        topic: "n1",
        waiting: "等你決定",
      },
      {
        home: "main",
        task: "after",
        kind: "ship",
        title: "title after",
        topic: "lt",
        waiting: "等 ready、held 完成",
      },
      {
        home: "main",
        task: "loose",
        kind: "ship",
        title: "title loose",
        topic: null,
        waiting: null,
      },
      {
        home: "main",
        task: "merged-away",
        kind: "ship",
        title: "title merged-away",
        topic: "n1",
        waiting: null,
      },
      { home: "sm1", task: "far", kind: "ship", title: "title far", topic: "hi", waiting: null },
    ]);
  });

  it("says a hold comes before blockers when an item has both", () => {
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({ queued: [item("both", { hold: "later", blockers: ["x"] })] }),
          }),
        ],
      }),
    );
    expect(view.queued.map((entry) => entry.waiting)).toEqual(["停著：later"]);
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
      finished: false,
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
      "sm/theirs=done:done:",
    ]);
    expect(view.agents.map((agent) => `${agent.task}:${agent.finished}`)).toEqual([
      "alive:false",
      "merged:true",
      "cleaned:true",
      "theirs:true",
    ]);
  });

  it("lists only work items, never a mate's own record or a remote mate's reply channel", () => {
    const dispatched = (taskId: string, kind: string, ts: number, homeId = "main") => ({
      ...ledger(taskId, "task.dispatched", ts, homeId),
      fields: { kind },
    });
    const view = buildView(
      input({
        homes: [
          home("main", {
            report: report({
              tasks: [task("open", "working"), task("live-mate", "working", "secondmate")],
              status_decisions: [
                { id: "live-mate", key: "relay", summary: "a child's call" },
                { id: "open", key: "k", summary: "which API?" },
              ],
              topics: { "retired-mate": tag("hi"), "old-work": tag("n2") },
            }),
          }),
          home("far", { remote: true, report: report() }),
        ],
        events: [
          dispatched("retired-mate", "secondmate", T0),
          ledger("retired-mate", "task.status", T0 + 1),
          ledger("retired-mate", "task.cleaned_up", T0 + 2),
          ledger("live-mate", "task.status", T0 + 3),
          ledger("parent-replies", "task.status", T0 + 4, "far"),
          ledger("parent-replies", "task.status", T0 + 5, "far"),
          dispatched("far-work", "scout", T0 + 6, "far"),
          ledger("far-work", "task.cleaned_up", T0 + 7, "far"),
          ledger("old-work", "task.status", T0 + 8),
          ledger("old-work", "task.cleaned_up", T0 + 9),
          ledger("old-pr", "task.pr_ready", T0 + 10),
          dispatched("reused", "secondmate", T0 + 11),
          ledger("reused", "task.cleaned_up", T0 + 12),
          dispatched("reused", "ship", T0 + 13),
          ledger("reused", "task.merged", T0 + 14),
        ],
      }),
    );
    expect(view.agents.map((agent) => `${agent.home}/${agent.task}:${agent.finished}`)).toEqual([
      "main/open:false",
      "main/old-work:true",
      "main/old-pr:true",
      "main/reused:true",
      "far/far-work:true",
    ]);
    expect(view.agents.find((agent) => agent.task === "old-work")?.topic).toBe("n2");
    expect(view.questions.map((question) => question.task)).toEqual(["open"]);
    const updates = view.updates.map((update) => `${update.home}/${update.task}:${update.topic}`);
    expect(updates).toContain("main/retired-mate:hi");
    expect(updates).toContain("far/parent-replies:null");
  });

  it("tells a ship task that was cleaned up without landing from one that landed", () => {
    const dispatched = (taskId: string, kind: string, ts: number): JournalEvent => ({
      src: "ledger",
      home: "main",
      ts,
      event: "task.dispatched",
      task: taskId,
      fields: { kind },
    });
    const view = buildView(
      input({
        homes: [home("main", { report: report() })],
        events: [
          dispatched("landed", "ship", T0),
          ledger("landed", "task.merged", T0 + 1),
          ledger("landed", "task.cleaned_up", T0 + 2),
          dispatched("dropped", "ship", T0 + 3),
          ledger("dropped", "task.status", T0 + 4),
          ledger("dropped", "task.cleaned_up", T0 + 5),
          dispatched("scouted", "scout", T0 + 6),
          ledger("scouted", "task.cleaned_up", T0 + 7),
          ledger("redone", "task.merged", T0 + 8),
          dispatched("redone", "ship", T0 + 9),
          ledger("redone", "task.cleaned_up", T0 + 10),
          ledger("undated", "task.cleaned_up", T0 + 11),
        ],
      }),
    );
    expect(
      view.agents.map((agent) => `${agent.task}=${agent.light}:${agent.state}:${agent.kind}`),
    ).toEqual([
      "landed=done:done:ship",
      "dropped=unknown:discarded:ship",
      "scouted=done:done:scout",
      "redone=unknown:discarded:ship",
      "undated=done:done:",
    ]);
    expect(view.agents.find((agent) => agent.task === "dropped")?.detail).toBe(
      "已收掉，帳本裡沒有落地紀錄",
    );
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
      todo: null,
      on_answer: "release",
      on_answer_recorded: false,
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

describe("hands-on items", () => {
  const COMMAND = 'sudo launchctl kickstart -k "system/x" && echo $HOME `date`\n\tps aux | grep x';
  const todoHold = (id: string, text = `動手：重啟 x（路由卡住）\n${COMMAND}`): ReportHold =>
    hold(id, { question: text });
  const built = (state: TopicState, homes: HomeSnapshot[]) =>
    Object.fromEntries(
      buildView(input({ topics: state, homes })).holds.map((entry) => [
        `${entry.home}/${entry.task}`,
        entry,
      ]),
    );

  it("shows a record from before the labels as it always did: the rest as one command", () => {
    expect(parseTodo(`動手：重啟 x（路由卡住）\n${COMMAND}\n`)).toEqual({
      what: "重啟 x（路由卡住）",
      guidance: "",
      commands: [COMMAND],
    });
    expect(parseTodo("動手：開 NAS 的兩步驟驗證\n只在你人在電腦前時做。")).toEqual({
      what: "開 NAS 的兩步驟驗證",
      guidance: "",
      commands: ["只在你人在電腦前時做。"],
    });
    expect(parseTodo("動手：查路由器的轉址")).toEqual({
      what: "查路由器的轉址",
      guidance: "",
      commands: [],
    });
    expect(parseTodo("動手： 登入 App Store \n\n")).toEqual({
      what: "登入 App Store",
      guidance: "",
      commands: [],
    });
    expect(parseTodo("請決定\n動手：不是開頭")).toBeNull();
    expect(parseTodo("")).toBeNull();
  });

  it("reads the labelled parts todo add writes, each command kept exactly", () => {
    expect(parseTodo("動手：開 NAS 的兩步驟驗證\n說明：只在你人在電腦前時做。\n\n")).toEqual({
      what: "開 NAS 的兩步驟驗證",
      guidance: "只在你人在電腦前時做。",
      commands: [],
    });
    expect(
      parseTodo(
        [
          "動手：裝新的設定",
          "說明：先關掉 VPN。",
          "說明：  第二行說明",
          "指令：sudo tee /etc/x.conf <<'EOF'",
          "續：\tkey = 1",
          "續：",
          "續：指令：這一行是 here-document 的內容",
          "續：EOF",
          "指令：sudo systemctl restart x \\",
          "續：  --now",
          "指令：說明：也只是指令",
        ].join("\n"),
      ),
    ).toEqual({
      what: "裝新的設定",
      guidance: "先關掉 VPN。\n  第二行說明",
      commands: [
        "sudo tee /etc/x.conf <<'EOF'\n\tkey = 1\n\n指令：這一行是 here-document 的內容\nEOF",
        "sudo systemctl restart x \\\n  --now",
        "說明：也只是指令",
      ],
    });
  });

  it("treats a record with any unlabelled line as one from before the labels", () => {
    const old = "動手：重啟 x\n說明：看起來像新的\nsudo x --now";
    expect(parseTodo(old)).toEqual({
      what: "重啟 x",
      guidance: "",
      commands: ["說明：看起來像新的\nsudo x --now"],
    });
    expect(parseTodo("動手：重啟 x\n續：沒有前面的指令")?.commands).toEqual(["續：沒有前面的指令"]);
    expect(parseTodo("動手：重啟 x\n說明：a\n續：b")?.commands).toEqual(["說明：a\n續：b"]);
  });

  it("shows the mark firstmate or the captain left, and no option buttons", () => {
    const state = topics();
    state.doc.todos = {
      claimed: { state: "claimed", at: "t" },
      rejected: { state: "rejected", at: "t", reason: "沒起來" },
      obsolete: { state: "obsolete", at: "t", reason: "不用了" },
      plain: { state: "claimed", at: "t" },
      labelled: { state: "rejected", at: "t", reason: "還是不行" },
    };
    state.doc.todos["constructor"] = { state: "claimed", at: "t" };
    const holds = built(state, [
      home("main", {
        report: report({
          holds: [
            todoHold("open", "動手：選一個\n選項：甲 | 乙"),
            todoHold("claimed"),
            todoHold("rejected"),
            todoHold("obsolete"),
            hold("plain"),
            todoHold("toString"),
            todoHold("labelled", "動手：登入\n說明：用公司的帳號"),
          ],
        }),
      }),
    ]);
    expect(holds["main/open"]?.todo).toEqual({
      what: "選一個",
      guidance: "",
      commands: ["選項：甲 | 乙"],
      state: "open",
      reason: null,
    });
    expect(holds["main/open"]?.options).toEqual([]);
    expect(holds["main/claimed"]?.todo).toMatchObject({ state: "claimed", commands: [COMMAND] });
    expect(holds["main/rejected"]?.todo).toMatchObject({ state: "rejected", reason: "沒起來" });
    expect(holds["main/obsolete"]?.todo).toMatchObject({ state: "obsolete", reason: "不用了" });
    expect(holds["main/plain"]?.todo).toBeNull();
    expect(holds["main/toString"]?.todo?.state).toBe("open");
    expect(holds["main/labelled"]?.todo).toEqual({
      what: "登入",
      guidance: "用公司的帳號",
      commands: [],
      state: "rejected",
      reason: "還是不行",
    });
  });

  it("answers as the hold recorded, else releases, except a main-home hands-on item", () => {
    const holds = built(topics(), [
      home("main", {
        report: report({
          holds: [
            hold("close", { on_answer: "close" }),
            hold("release", { on_answer: "release" }),
            hold("old-call"),
            todoHold("old-todo"),
            { ...todoHold("kept-todo"), on_answer: "release" },
          ],
        }),
      }),
      home("sm1", { report: report({ holds: [todoHold("mate-todo")] }) }),
    ]);
    const outcome = (key: string): string =>
      `${holds[key]?.on_answer}/${holds[key]?.on_answer_recorded}`;
    expect(outcome("main/close")).toBe("close/true");
    expect(outcome("main/release")).toBe("release/true");
    expect(outcome("main/old-call")).toBe("release/false");
    expect(outcome("main/old-todo")).toBe("close/false");
    expect(outcome("main/kept-todo")).toBe("release/true");
    expect(outcome("sm1/mate-todo")).toBe("release/false");
  });

  it("keeps an old hands-on item in play, but not one put off to a date or blocked", () => {
    const holds = built(topics(), [
      home("main", {
        report: report({
          holds: [
            { ...todoHold("old"), hold_bucket: "aged" },
            { ...todoHold("dated"), hold_bucket: "dated", hold_until: "2026-12-01" },
            hold("old-call", { hold_bucket: "aged" }),
          ],
        }),
      }),
    ]);
    expect(holds["main/old"]).toMatchObject({ live: true, deferred_reason: null });
    expect(holds["main/dated"]).toMatchObject({ live: false, deferred_reason: "延到 2026-12-01" });
    expect(holds["main/old-call"]).toMatchObject({
      live: false,
      deferred_reason: "已放超過 14 天",
    });
  });

  it("labels a queued hands-on item as something to do, not to decide", () => {
    const queued = (id: string): ReportQueued => ({
      id,
      kind: "captain",
      title: id,
      hold: "動手：登入",
      captain: true,
      blockers: [],
      topic_hint: null,
    });
    const view = buildView(
      input({
        homes: [
          home("main", { report: report({ queued: [queued("mine")] }) }),
          home("sm1", { report: report({ queued: [queued("theirs")] }) }),
        ],
      }),
    );
    expect(view.queued.map((entry) => entry.waiting)).toEqual(["要你動手", "等你決定"]);
  });

  it("treats the marker in a secondmate home as an ordinary question", () => {
    const state = topics();
    state.doc.todos = { same: { state: "claimed", at: "t" } };
    const holds = built(state, [
      home("main"),
      home("sm1", { report: report({ holds: [todoHold("same", "動手：x\n選項：甲 | 乙")] }) }),
    ]);
    expect(holds["sm1/same"]?.todo).toBeNull();
    expect(holds["sm1/same"]?.options).toEqual(["甲", "乙"]);
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
      close_reason: "all done",
      archived_at: null,
    });
    expect(view.topics["hi"]).toMatchObject({ queue: "high", close_reason: null });
    expect(view.topics["lt"]?.queue).toBe("later");
    expect(view.topics["gone"]).toEqual({
      name: "Gone",
      goal: "goal of Gone",
      status: "archived",
      queue: null,
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
