import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DecisionStore, decisionStep, holdSetSeconds } from "./decisions.js";
import type { DecisionRead, HomeDecisions, PageAnswer } from "./decisions.js";
import type { ClosedHold, HomeReport, ReportHold } from "./report.js";
import { shortTime } from "./todos.js";

const READ_AT = 1_795_300_000;
const SET = "2026-11-20T06:10:00Z";
const SET_S = Date.parse(SET) / 1000;

function hold(id: string, extra: Partial<ReportHold> = {}): ReportHold {
  return {
    id,
    title: "NAS 兩步驗證",
    question: "NAS 要不要開兩步驗證？\n選項：要 | 不要",
    hold_bucket: "live",
    hold_until: null,
    unresolved_blocker_ids: [],
    hold_age_days: 0,
    origin: "",
    on_answer: "close",
    hold_set: SET,
    ...extra,
  };
}

function closed(id: string, extra: Partial<ClosedHold> = {}): ClosedHold {
  return {
    id,
    title: "NAS 兩步驗證",
    origin: "",
    mode: "answered",
    answer: "要",
    label: "",
    source: "",
    digest: `d-${id}`,
    occurrence: 1,
    opened_at: null,
    closed_at: null,
    ...extra,
  };
}

function report(extra: Partial<HomeReport> = {}): HomeReport {
  return {
    code_commit: "c1",
    ledger_enabled: true,
    tasks: [],
    queued: [],
    holds: [],
    status_decisions: [],
    topics: {},
    ledger: { status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: [] },
    ledger_hint: null,
    aggregator: null,
    secondmates: [],
    closed_holds: [],
    closed_cursor: { status: "delta", to_offset: 10, to_prefix_sha256: "s", more: false },
    ...extra,
  };
}

/** Runs reads in order, each from what the one before remembered, collecting the saved keys. */
function reads(reports: HomeReport[], start?: HomeDecisions, pageAnswers: PageAnswer[] = []) {
  const saved = new Set<string>();
  const asked: string[] = [];
  let previous = start;
  const drafts: ReturnType<typeof decisionStep>["drafts"][] = [];
  for (const each of reports) {
    const input: DecisionRead = {
      home: "main",
      previous,
      report: each,
      readAt: READ_AT,
      saved: (key) => saved.has(key),
      topicOf: (task, origin) => (task === "tagged" || origin === "tagged" ? "nas" : null),
      pageAnswer: (task, answers) => {
        asked.push(`${task} ${answers.join("|")}`);
        return pageAnswers.shift() ?? "recorded";
      },
    };
    const step = decisionStep(input);
    for (const draft of step.drafts) if (draft.key !== undefined) saved.add(draft.key);
    drafts.push(step.drafts);
    previous = step.next;
  }
  return { drafts, last: previous as HomeDecisions, asked };
}

const START = { status: "start", to_offset: 10, to_prefix_sha256: "s", more: false } as const;

describe("decisionStep", () => {
  it("writes nothing on the first read, whatever the home already holds and closed", () => {
    const first = report({
      holds: [hold("open-1")],
      closed_holds: [closed("done-1"), closed("released-1", { mode: "released" })],
      closed_cursor: START,
    });
    const { drafts, last } = reads([first]);
    expect(drafts).toEqual([[]]);
    expect(last).toEqual({
      code_commit: "c1",
      cursor: { offset: 10, sha: "s" },
      openSeen: [`open-1\t${SET}`],
      closedSeen: ["done-1\td-done-1", "released-1\td-released-1"],
    });
  });

  it("writes nothing later for what was there at the first read: archived, finished, closed", () => {
    const { drafts } = reads([
      report({
        holds: [hold("open-1")],
        closed_holds: [closed("done-1"), closed("released-1", { mode: "released" })],
        closed_cursor: START,
      }),
      // Retention moved done-1 into the archive; released-1's work finished, its record kept.
      report({
        holds: [hold("open-1")],
        closed_holds: [closed("released-1", { mode: "released" }), closed("done-1")],
      }),
      report({
        holds: [hold("open-1")],
        closed_holds: [closed("released-1", { mode: "released" })],
      }),
    ]);
    expect(drafts.flat()).toEqual([]);
  });

  it("records an opening at its set time once, however long since the last read", () => {
    const { drafts } = reads([
      report({ closed_cursor: START }),
      report({ holds: [hold("tagged")] }),
      report({ holds: [hold("tagged")] }),
    ]);
    expect(drafts[1]).toEqual([
      {
        kind: "hold.opened",
        topic: "nas",
        home: "main",
        task: "tagged",
        key: `hold.opened\tmain\ttagged\t${SET}`,
        at: SET_S,
        text: "待決事項「NAS 兩步驗證」已開：NAS 要不要開兩步驗證？",
      },
    ]);
    expect(drafts[2]).toEqual([]);
  });

  it("does not record an opening twice when the memory of the last read was lost", () => {
    const first = reads([report({ closed_cursor: START }), report({ holds: [hold("x")] })]);
    const again = decisionStep({
      home: "main",
      previous: { ...first.last, openSeen: [] },
      report: report({ holds: [hold("x")] }),
      readAt: READ_AT,
      saved: (key) => key === `hold.opened\tmain\tx\t${SET}`,
      topicOf: () => null,
      pageAnswer: () => "recorded",
    });
    expect(again.drafts).toEqual([]);
  });

  it("starts the openings over when the home's reader runs other code, but keeps the closes", () => {
    const { drafts } = reads([
      report({ closed_cursor: START }),
      report({ code_commit: "c2", holds: [hold("new-1")], closed_holds: [closed("chat-1")] }),
    ]);
    expect(drafts[1]?.map((draft) => draft.kind)).toEqual(["hold.closed"]);
  });

  it("closes a decision answered in chat once, at the exact time when the home has it", () => {
    const { drafts } = reads([
      report({ closed_cursor: START, holds: [hold("tagged")] }),
      report({ closed_holds: [closed("tagged", { closed_at: SET_S + 60 })] }),
      report({ closed_holds: [closed("tagged", { closed_at: SET_S + 60 })] }),
    ]);
    expect(drafts[1]).toEqual([
      {
        kind: "hold.closed",
        topic: "nas",
        home: "main",
        task: "tagged",
        key: "hold.closed\tmain\ttagged\td-tagged",
        at: SET_S + 60,
        outcome: "answered",
        answer: "要",
        source: "chat",
        text: "待決事項「NAS 兩步驗證」已回答：要（經聊天）",
      },
    ]);
    expect(drafts[2]).toEqual([]);
  });

  it("says 'at the latest' this read when the home has no time for the close", () => {
    const { drafts } = reads([
      report({ closed_cursor: START, holds: [hold("x")] }),
      report({ closed_holds: [closed("x")] }),
    ]);
    expect(drafts[1]?.[0]?.at).toBe(READ_AT);
    expect(drafts[1]?.[0]?.text).toBe(
      `待決事項「NAS 兩步驗證」已回答：要（經聊天）（最晚 ${shortTime(new Date(READ_AT * 1000).toISOString())}）`,
    );
  });

  it("leaves a close the page delivered to the page's own record", () => {
    const page = closed("x", { source: "myshape", answer: "A", label: "要", closed_at: SET_S + 5 });
    const { drafts, asked } = reads([
      report({ closed_cursor: START, holds: [hold("x")] }),
      report({ closed_holds: [page] }),
      report({ closed_holds: [page] }),
    ]);
    expect(drafts.flat()).toEqual([]);
    expect(asked).toEqual(["x A|要"]);
  });

  it("waits, with the cursor kept, while the page is still sending its answer", () => {
    const page = closed("x", { source: "myshape", closed_at: SET_S + 5 });
    const moved = { status: "delta", to_offset: 99, to_prefix_sha256: "t", more: false } as const;
    const { drafts, last } = reads(
      [
        report({ closed_cursor: START, holds: [hold("x")] }),
        report({ closed_holds: [page], closed_cursor: moved }),
        report({ closed_holds: [page], closed_cursor: moved }),
      ],
      undefined,
      ["pending", "recorded"],
    );
    expect(drafts.flat()).toEqual([]);
    expect(last.cursor).toEqual({ offset: 99, sha: "t" });
  });

  it("closes like any other a page answer the board has no record of", () => {
    const page = closed("x", { source: "myshape", closed_at: SET_S + 5 });
    const { drafts, last } = reads(
      [
        report({ closed_cursor: START, holds: [hold("x")] }),
        report({ closed_holds: [page] }),
        report({ closed_holds: [page] }),
      ],
      undefined,
      ["pending", "none"],
    );
    expect(drafts[1]).toEqual([]);
    expect(drafts[2]?.map((draft) => `${draft.kind} ${draft.source} ${draft.text}`)).toEqual([
      "hold.closed myshape 待決事項「NAS 兩步驗證」已回答：要（經看板）",
    ]);
    expect(last.closedSeen).toEqual(["x\td-x"]);
  });

  it("keeps the cursor where it was while a page answer waits", () => {
    const page = closed("x", { source: "myshape", closed_at: SET_S + 5 });
    const moved = { status: "delta", to_offset: 99, to_prefix_sha256: "t", more: false } as const;
    const { last } = reads(
      [
        report({ closed_cursor: START, holds: [hold("x")] }),
        report({ closed_holds: [page], closed_cursor: moved }),
      ],
      undefined,
      ["pending"],
    );
    expect(last.cursor).toEqual({ offset: 10, sha: "s" });
    expect(last.closedSeen).toEqual([]);
  });

  it("opens and closes a decision that came and went between two reads", () => {
    const { drafts } = reads([
      report({ closed_cursor: START }),
      report({ closed_holds: [closed("x", { opened_at: SET_S, closed_at: SET_S + 9 })] }),
    ]);
    expect(drafts[1]?.map((draft) => [draft.kind, draft.at, draft.text])).toEqual([
      ["hold.opened", SET_S, "待決事項「NAS 兩步驗證」已開"],
      ["hold.closed", SET_S + 9, "待決事項「NAS 兩步驗證」已回答：要（經聊天）"],
    ]);
  });

  it("does not open again a decision the last read showed open", () => {
    const { drafts } = reads([
      report({ closed_cursor: START, holds: [hold("x")] }),
      report({ closed_holds: [closed("x", { opened_at: SET_S, closed_at: SET_S + 9 })] }),
    ]);
    expect(drafts[1]?.map((draft) => draft.kind)).toEqual(["hold.closed"]);
  });

  it("records no close from a home whose reader reports none", () => {
    const old = { closed_holds: [], closed_cursor: null };
    const { drafts, last } = reads([
      report({ ...old, holds: [hold("x", { hold_set: null })] }),
      report({ ...old, holds: [] }),
    ]);
    expect(drafts.flat()).toEqual([]);
    expect(last.cursor).toBeNull();
  });

  it("puts an opening it cannot time at this read, with 'at the latest'", () => {
    const { drafts } = reads([
      report({ closed_cursor: START }),
      report({ holds: [hold("x", { hold_set: "2026-11-20", question: "" })] }),
    ]);
    expect(drafts[1]?.[0]).toMatchObject({
      at: READ_AT,
      text: `待決事項「NAS 兩步驗證」已開（最晚 ${shortTime(new Date(READ_AT * 1000).toISOString())}）`,
    });
  });

  it("says how each kind of close ended", () => {
    const modes: [Partial<ClosedHold>, string][] = [
      [{ mode: "", source: "lavish" }, "已回答：要（經lavish）"],
      [{ mode: "repaired" }, "已回答：要（經聊天，事後補記）"],
      [{ mode: "released", label: "好" }, "已回答並放行，工作繼續：好（經聊天）"],
      [{ mode: "reconciled", answer: "PR 已合併" }, "已對帳結束，不必再答：PR 已合併"],
      [{ mode: "forge-closed", answer: "" }, "隨 PR 結束而關閉"],
      [{ mode: "forge-released", answer: "" }, "隨 PR 結束而放行，工作繼續"],
      [{ mode: "declined", title: "" }, "待決事項已結束（declined）：要"],
    ];
    for (const [extra, words] of modes) {
      const { drafts } = reads([
        report({ closed_cursor: START }),
        report({ closed_holds: [closed("x", { closed_at: 1, ...extra })] }),
      ]);
      expect(drafts[1]?.[0]?.text.endsWith(words), words).toBe(true);
    }
  });
});

describe("decisionStep's edges", () => {
  it("cuts a long first line, keeps one exactly at the limit, and names an untitled decision", () => {
    const long = "問".repeat(201);
    const edge = "答".repeat(200);
    const { drafts } = reads([
      report({ closed_cursor: START }),
      report({ holds: [hold("a", { question: long }), hold("b", { question: edge, title: "" })] }),
    ]);
    expect(drafts[1]?.map((draft) => draft.text)).toEqual([
      `待決事項「NAS 兩步驗證」已開：${"問".repeat(200)}…`,
      `待決事項已開：${edge}`,
    ]);
  });

  it("records the mode as the outcome, an empty one as answered", () => {
    const { drafts } = reads([
      report({ closed_cursor: START }),
      report({
        closed_holds: [
          closed("a", { mode: "", closed_at: 1 }),
          closed("b", { mode: "released", source: "lavish", closed_at: 1 }),
        ],
      }),
    ]);
    expect(drafts[1]?.map((draft) => `${draft.outcome} ${draft.source}`)).toEqual([
      "answered chat",
      "released lavish",
    ]);
  });

  it("does not open again a decision whose gap opening is already saved", () => {
    const first = reads([report({ closed_cursor: START })]);
    const step = decisionStep({
      home: "main",
      previous: first.last,
      report: report({ closed_holds: [closed("x", { opened_at: 5, closed_at: 9 })] }),
      readAt: READ_AT,
      saved: (key) => key === "hold.opened\tmain\tx\t#d-x",
      topicOf: () => null,
      pageAnswer: () => "recorded",
    });
    expect(step.drafts.map((draft) => draft.kind)).toEqual(["hold.closed"]);
  });
});

describe("holdSetSeconds", () => {
  it("reads a full stamp and nothing else", () => {
    expect(holdSetSeconds(SET)).toBe(SET_S);
    for (const stamp of [null, "2026-11-20", "soon", "2026-11-20T06:10:00"])
      expect(holdSetSeconds(stamp)).toBeNull();
  });
});

describe("DecisionStore", () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-decisions-"));
  });
  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  const seen: HomeDecisions = {
    code_commit: "c1",
    cursor: { offset: 3, sha: "s" },
    openSeen: ["a\tT"],
    closedSeen: ["b\td"],
  };

  it("keeps each home across a restart, and forgets one on request", () => {
    const file = path.join(dir, "decisions.json");
    new DecisionStore(file).set("main", seen);
    const again = new DecisionStore(file);
    expect(again.get("main")).toEqual(seen);
    again.forget("main");
    expect(new DecisionStore(file).get("main")).toBeUndefined();
  });

  it("does not rewrite the file for a read that changed nothing", () => {
    const file = path.join(dir, "decisions.json");
    const store = new DecisionStore(file);
    store.set("main", seen);
    fs.writeFileSync(file, "marker");
    store.set("main", { ...seen });
    expect(fs.readFileSync(file, "utf8")).toBe("marker");
  });

  it("starts empty from a missing or unreadable file", () => {
    const file = path.join(dir, "decisions.json");
    expect(new DecisionStore(file).get("main")).toBeUndefined();
    fs.writeFileSync(file, "{not json");
    expect(new DecisionStore(file).get("main")).toBeUndefined();
    fs.writeFileSync(file, JSON.stringify({ v: 2, homes: { main: seen } }));
    expect(new DecisionStore(file).get("main")).toBeUndefined();
    fs.writeFileSync(
      file,
      JSON.stringify({ v: 1, homes: { main: { cursor: { offset: "3", sha: "s" } } } }),
    );
    expect(new DecisionStore(file).get("main")?.cursor).toBeNull();
    fs.writeFileSync(file, JSON.stringify({ v: 1, homes: { main: { cursor: { offset: 3 } } } }));
    expect(new DecisionStore(file).get("main")?.cursor).toBeNull();
    fs.writeFileSync(file, JSON.stringify({ v: 1, homes: { main: { cursor: 3 } } }));
    expect(new DecisionStore(file).get("main")).toEqual({
      code_commit: "",
      cursor: null,
      openSeen: [],
      closedSeen: [],
    });
  });
});
