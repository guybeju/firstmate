// The write engine, the four captain actions, and the browser API routes,
// driven together against a scripted command runner.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as actions from "./actions.js";
import type { ActionContext, ActionResult } from "./actions.js";
import { createApi } from "./api.js";
import type { AllowedCommand, CommandResult, Secondmate } from "./commands.js";
import { ConfirmStore } from "./confirm.js";
import type { ApiHandler } from "./http.js";
import type { BoardResponse } from "./protocol.js";
import type { HomeReport } from "./report.js";
import { emptyState } from "./topics.js";
import type { TopicState } from "./topics.js";
import type { HomeSnapshot } from "./view.js";
import { WriteEngine, isDedupable } from "./writes.js";
import type { WriteRecord, WriteTimings } from "./writes.js";

const SECONDMATES: Secondmate[] = [
  { id: "sm1", remote: false, home: "/h/sm1" },
  { id: "far1", remote: true, home: "/h/far1" },
  { id: "down", remote: true, home: "/h/down" },
];
const OK: CommandResult = { code: 0, stdout: "", stderr: "" };
const exit = (code: number | null, stdout = "", stderr = ""): CommandResult => ({
  code,
  stdout,
  stderr,
});

interface Harness {
  engine: WriteEngine;
  context: ActionContext;
  calls: AllowedCommand[];
  /** Results for the next commands of a kind, in order; anything unscripted succeeds. */
  script: (kind: AllowedCommand["kind"], ...results: CommandResult[]) => void;
  tags: Map<string, string | null>;
  delivered: WriteRecord[];
  changes: () => number;
  audit: () => Record<string, unknown>[];
  restart: (timings?: Partial<WriteTimings>) => Harness;
}

let dir: string;
let open: WriteEngine[];

function topics(): TopicState {
  const state = emptyState();
  const topic = (name: string, status: "confirmed" | "proposed" = "confirmed") => ({
    name,
    goal: "g",
    status,
    created_at: "",
    proposed_by: "firstmate" as const,
  });
  state.doc.topics = {
    billing: topic("Billing"),
    login: topic("Login"),
    idea: topic("Idea", "proposed"),
  };
  state.doc.queues = { high: [], normal: ["billing", "login"], later: [] };
  state.doc.merged = { old: "billing" };
  state.archive.topics = { gone: { ...topic("Gone"), archived_at: "T" } };
  return state;
}

function report(extra: Partial<HomeReport>): HomeReport {
  return {
    code_commit: "c",
    ledger_enabled: true,
    tasks: [],
    queued: [],
    holds: [],
    status_decisions: [],
    topics: {},
    ledger: { status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: [] },
    secondmates: [],
    ...extra,
  };
}

const hold = (id: string, origin = "") => ({
  id,
  title: "T",
  question: `q of ${id}`,
  hold_bucket: "live" as const,
  hold_until: null,
  unresolved_blocker_ids: [],
  hold_age_days: 1,
  origin,
});

function homes(): HomeSnapshot[] {
  const snapshot = (id: string, remote: boolean, extra: Partial<HomeReport>): HomeSnapshot => ({
    id,
    remote,
    report: report(extra),
    lastOkAt: 1,
    error: null,
    version: "same",
  });
  return [
    snapshot("main", false, {
      holds: [hold("call-1", "ship-a"), hold("call-origin", "ship-a"), hold("call-loose")],
      topics: { "ship-a": "billing T", "call-1": "login T", tagged: "login T1\nbilling T2" },
    }),
    snapshot("sm1", false, { holds: [hold("call-sm")] }),
    snapshot("far1", true, { holds: [hold("call-far")], topics: { "far-work": "billing T" } }),
    {
      id: "down",
      remote: true,
      report: null,
      lastOkAt: null,
      error: "unreachable",
      version: "unknown",
    },
  ];
}

function harness(
  timings: Partial<WriteTimings> = {},
  auditFile = path.join(dir, "audit.jsonl"),
): Harness {
  const scripts = new Map<string, CommandResult[]>();
  const calls: AllowedCommand[] = [];
  const tags = new Map<string, string | null>();
  const delivered: WriteRecord[] = [];
  let changes = 0;
  const engine = new WriteEngine(
    auditFile,
    {
      run: async (command) => {
        calls.push(command);
        return scripts.get(command.kind)?.shift() ?? OK;
      },
      secondmates: () => SECONDMATES,
      readTags: async (home, task) =>
        tags.has(`${home}/${task}`) ? (tags.get(`${home}/${task}`) as string | null) : "",
      prepare: async () => undefined,
      onChange: () => {
        changes += 1;
      },
      onDelivered: (record) => delivered.push(record),
    },
    { retryDelaysMs: [5, 5], resumeWindowMs: 60_000, commandTimeoutMs: 1000, ...timings },
  );
  open.push(engine);
  return {
    engine,
    context: { topics: topics(), homes: homes(), secondmates: SECONDMATES, writes: engine },
    calls,
    script: (kind, ...results) => scripts.set(kind, results),
    tags,
    delivered,
    changes: () => changes,
    audit: () =>
      fs
        .readFileSync(auditFile, "utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line) as Record<string, unknown>),
    restart: (next = {}) => {
      engine.stop();
      return harness({ ...timings, ...next }, auditFile);
    },
  };
}

function sent(result: ActionResult): WriteRecord {
  if (!result.ok) throw new Error(`refused: ${result.line}`);
  return result.write;
}

function refused(result: ActionResult): string {
  if (result.ok) throw new Error("the action was accepted");
  return result.line;
}

async function settled(record: WriteRecord, state: WriteRecord["state"]): Promise<void> {
  await vi.waitFor(() => expect(record.state).toBe(state), { timeout: 2000, interval: 2 });
}

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-sending-"));
  open = [];
});
afterEach(() => {
  for (const engine of open) engine.stop();
  fs.rmSync(dir, { recursive: true, force: true });
});

describe("message", () => {
  it("sends one note naming the topic and records it", async () => {
    const h = harness();
    const write = sent(actions.message(h.context, "old", "  請先做帳務  ", "browser"));
    expect(write).toMatchObject({
      channel: "browser",
      home: "main",
      task: null,
      topic: "billing",
      text: "請先做帳務",
      state: "sending",
      attempt: 0,
    });
    expect(write.id).toMatch(/^w-[0-9a-z]+-[0-9a-f]{6}$/);
    await settled(write, "delivered");
    expect(h.calls).toEqual([
      {
        kind: "note",
        requestId: expect.stringMatching(/^tb-[0-9a-f]{16}$/),
        body: "［議題：Billing（billing）］\n請先做帳務",
      },
    ]);
    expect(h.audit().map((line) => line["state"])).toEqual(["sending", "delivered"]);
    expect(h.audit()[0]).toMatchObject({
      write_id: write.id,
      attempt: 0,
      sending: { text: "請先做帳務", plan: { type: "note" } },
    });
    expect(fs.statSync(path.join(dir, "audit.jsonl")).mode & 0o777).toBe(0o600);
    expect(h.delivered).toEqual([write]);
    expect(h.changes()).toBe(1);
  });

  it("accepts an archived topic and refuses an unknown one or empty or oversized text", () => {
    const h = harness();
    expect(sent(actions.message(h.context, "gone", "x", "socket")).topic).toBe("gone");
    expect(refused(actions.message(h.context, "nope", "x", "socket"))).toBe("沒有 nope 這個議題。");
    expect(refused(actions.message(h.context, "billing", "  ", "socket"))).toContain(
      "訊息要有內容",
    );
    expect(refused(actions.message(h.context, "billing", "x".repeat(4001), "socket"))).toContain(
      "4000",
    );
    expect(actions.message(h.context, "billing", "x".repeat(4000), "socket").ok).toBe(true);
  });

  it("replays a note that did not wake firstmate, then gives up as undelivered", async () => {
    const h = harness();
    h.script("note", exit(3, "", "saved, not woken"), exit(3), OK);
    const woken = sent(actions.message(h.context, "billing", "a", "browser"));
    await settled(woken, "delivered");
    expect(
      new Set(h.calls.map((call) => (call.kind === "note" ? call.requestId : ""))),
    ).toHaveProperty("size", 1);
    expect(h.calls).toHaveLength(3);
    expect(h.audit().map((line) => `${String(line["state"])}:${String(line["attempt"])}`)).toEqual([
      "sending:0",
      "retrying:1",
      "retrying:2",
      "delivered:2",
    ]);
    expect(h.audit()[1]).toMatchObject({ error: "saved, not woken", next_at: expect.any(String) });
    const retry = h.audit()[1] as { ts: string; next_at: string };
    expect(Date.parse(retry.next_at)).toBeGreaterThanOrEqual(Date.parse(retry.ts));

    h.script("note", exit(3), exit(3), exit(3, "", "still asleep"));
    const stuck = sent(actions.message(h.context, "billing", "b", "browser"));
    await settled(stuck, "undelivered");
    expect(stuck.error).toBe("still asleep");
    expect(h.calls).toHaveLength(6);
    expect(h.delivered).toEqual([woken]);
  });

  it("fails at once on any other exit code, with the reason", async () => {
    const h = harness();
    h.script("note", exit(1, "from stdout"), exit(null), exit(2, "", "x".repeat(700)));
    const first = sent(actions.message(h.context, "billing", "a", "browser"));
    const second = sent(actions.message(h.context, "billing", "b", "browser"));
    const third = sent(actions.message(h.context, "billing", "c", "browser"));
    await settled(third, "failed");
    expect(first).toMatchObject({ state: "failed", error: "from stdout", attempt: 0 });
    expect(second.error).toBe("exit ?");
    expect(third.error).toHaveLength(600);
    expect(h.calls).toHaveLength(3);
  });
});

describe("direct", () => {
  it("writes to a main-home worker and relays through a secondmate otherwise", async () => {
    const h = harness();
    const main = sent(actions.direct(h.context, "main", "ship-a", "看一下 CI", "browser"));
    const local = sent(actions.direct(h.context, "sm1", "sm-work", "同機", "browser"));
    const remote = sent(actions.direct(h.context, "far1", "far-work", "遠端", "browser"));
    await settled(remote, "delivered");
    await settled(local, "delivered");
    expect(main).toMatchObject({ topic: "billing", plan: { type: "send", task: "ship-a" } });
    expect(local).toMatchObject({
      topic: null,
      plan: { type: "relay", secondmate: "sm1", remote: false },
    });
    expect(remote).toMatchObject({
      topic: "billing",
      plan: { type: "relay", secondmate: "far1", remote: true },
    });
    expect(h.calls).toContainEqual({ kind: "send", task: "ship-a", text: "看一下 CI" });
    expect(h.calls).toContainEqual({
      kind: "relay",
      secondmate: "far1",
      deliveryId: expect.stringMatching(/^[a-f0-9]{16}$/),
      text: "轉給 far-work：遠端",
    });
    expect(h.calls).toContainEqual({
      kind: "relay",
      secondmate: "sm1",
      deliveryId: expect.stringMatching(/^[a-f0-9]{16}$/),
      text: "轉給 sm-work：同機",
    });
  });

  it("refuses unknown homes, bad task ids, and command-like or oversized text", () => {
    const h = harness();
    expect(refused(actions.direct(h.context, "nobody", "t", "x", "browser"))).toBe(
      "不認得 home nobody。",
    );
    expect(refused(actions.direct(h.context, "main", "-t", "x", "browser"))).toBe(
      "task id 格式不對：-t",
    );
    expect(refused(actions.direct(h.context, "main", "t", "/compact", "browser"))).toContain(
      "會被當成指令",
    );
    expect(refused(actions.direct(h.context, "far1", "t", "-x", "browser"))).toContain(
      "會被當成指令",
    );
    expect(refused(actions.direct(h.context, "main", "t", "", "browser"))).toBe("訊息不能是空的。");
    expect(refused(actions.direct(h.context, "main", "t", "x".repeat(4001), "browser"))).toBe(
      "訊息最多 4000 個字。",
    );
    expect(h.calls).toEqual([]);
    expect(actions.direct(h.context, "main", "t", "x".repeat(4000), "browser").ok).toBe(true);
  });

  it("retries an unconfirmed remote relay with the same id, but not a local one or a plain send", async () => {
    const h = harness();
    h.script("relay", exit(3), OK, exit(3, "", "local unconfirmed"));
    const remote = sent(actions.direct(h.context, "far1", "w", "a", "browser"));
    await settled(remote, "delivered");
    const relays = h.calls.filter((call) => call.kind === "relay");
    expect(relays).toHaveLength(2);
    expect(relays[0]).toEqual(relays[1]);
    const local = sent(actions.direct(h.context, "sm1", "w", "b", "browser"));
    await settled(local, "failed");
    expect(local.error).toBe("local unconfirmed");
    h.script("relay", exit(1, "", "no such secondmate"));
    const broken = sent(actions.direct(h.context, "far1", "w", "c", "browser"));
    await settled(broken, "failed");
    h.script("send", exit(3, "", "typed, unconfirmed"));
    const plain = sent(actions.direct(h.context, "main", "w", "d", "browser"));
    await settled(plain, "failed");
    expect(plain.error).toBe("typed, unconfirmed");
    const upstream =
      "error: target 'w' is not resolvable (tried meta=/h/state/w.meta; backend=none). Use fm-w";
    h.script("send", exit(1, "", upstream));
    const ended = sent(actions.direct(h.context, "main", "w", "e", "browser"));
    await settled(ended, "failed");
    expect(ended.error).toBe("這個 worker 已經結束或找不到，訊息沒有送出。");
  });
});

describe("answer", () => {
  const input = (extra: Partial<actions.AnswerInput> = {}): actions.AnswerInput => ({
    home: "main",
    task: "call-1",
    answer: "合併",
    label: "合併",
    mode: "release",
    ...extra,
  });

  it("records the answer on the hold, then tells firstmate once", async () => {
    const h = harness();
    h.script("answer", exit(0, "closed: call-1\nanswers: closed=1 skipped=0"));
    const write = sent(actions.answer(h.context, input(), "browser"));
    expect(write).toMatchObject({ home: "main", task: "call-1", topic: "login", text: "合併" });
    await settled(write, "delivered");
    expect(h.calls).toEqual([
      { kind: "answer", placement: "main", line: "call-1\t合併\t合併\trelease" },
      {
        kind: "note",
        requestId: `tb-${write.id}-note`,
        body: "［議題：Login］已在看板回答 main/call-1：合併",
      },
    ]);
    expect(h.audit().map((line) => line["step"] ?? line["state"])).toEqual([
      "sending",
      "answered",
      "delivered",
    ]);
  });

  it("places the answer where the hold lives and names the topic by task, origin, or neither", async () => {
    const h = harness();
    h.script(
      "answer",
      exit(0, "closed: call-sm"),
      exit(0, "closed: call-far"),
      exit(0, "closed: call-origin"),
      exit(0, "closed: call-loose"),
    );
    const local = sent(
      actions.answer(h.context, input({ home: "sm1", task: "call-sm", mode: "done" }), "browser"),
    );
    await settled(local, "delivered");
    const remote = sent(
      actions.answer(h.context, input({ home: "far1", task: "call-far" }), "browser"),
    );
    await settled(remote, "delivered");
    const viaOrigin = sent(actions.answer(h.context, input({ task: "call-origin" }), "browser"));
    await settled(viaOrigin, "delivered");
    const loose = sent(actions.answer(h.context, input({ task: "call-loose" }), "browser"));
    await settled(loose, "delivered");
    const answers = h.calls.filter((call) => call.kind === "answer");
    expect(answers[0]).toEqual({
      kind: "answer",
      placement: "local",
      secondmate: "sm1",
      line: "call-sm\t合併\t合併\tdone",
    });
    expect(answers[1]).toEqual({
      kind: "answer",
      placement: "remote",
      secondmate: "far1",
      line: "call-far\t合併\t合併\trelease",
    });
    expect(viaOrigin.topic).toBe("billing");
    expect(loose.topic).toBeNull();
    const notes = h.calls
      .filter((call) => call.kind === "note")
      .map((call) => (call.kind === "note" ? call.body : ""));
    expect(notes).toEqual([
      "［議題：未分類］已在看板回答 sm1/call-sm：合併",
      "［議題：未分類］已在看板回答 far1/call-far：合併",
      "［議題：Billing］已在看板回答 main/call-origin：合併",
      "［議題：未分類］已在看板回答 main/call-loose：合併",
    ]);
  });

  it("reads the verdict line for its task, not the exit code", async () => {
    const h = harness();
    const run = async (
      result: CommandResult,
      extra: Partial<actions.AnswerInput> = {},
    ): Promise<WriteRecord> => {
      h.script("answer", result);
      const write = sent(actions.answer(h.context, input(extra), "browser"));
      await vi.waitFor(() => expect(["sending", "retrying"]).not.toContain(write.state), {
        timeout: 2000,
        interval: 2,
      });
      return write;
    };
    expect(
      (await run(exit(1, "skipped: call-1 (already closed)\nanswers: closed=0 skipped=1"))).state,
    ).toBe("handled_elsewhere");
    const elsewhere =
      "skipped: call-1 (task call-1 records a different captain decision with mode released)";
    expect((await run(exit(1, `${elsewhere}\nanswers: closed=0 skipped=1`))).state).toBe(
      "handled_elsewhere",
    );
    const refusedAway = await run(exit(1, "refused: call-1 (away posture)"));
    expect(refusedAway).toMatchObject({ state: "failed", error: "refused: call-1 (away posture)" });
    const released = await run(exit(1, "skipped: call-1 (not held for the captain)"));
    expect(released).toMatchObject({ state: "handled_elsewhere", error: null });
    expect(
      (await run(exit(1, "closed: call-10\nskipped: other (already closed)", "tasks-axi missing")))
        .error,
    ).toBe("tasks-axi missing");
    const answers = (): number => h.calls.filter((call) => call.kind === "answer").length;
    const before = answers();
    expect((await run(exit(255, "", "ssh died"))).state).toBe("failed");
    expect(answers()).toBe(before + 1);
    const remote = await run(exit(1, "", "remote said no"), { home: "far1", task: "call-far" });
    expect(remote).toMatchObject({ state: "failed", error: "remote said no" });
    expect(answers()).toBe(before + 2);
    expect((await run(exit(0, ""))).error).toBe("exit 0");
    expect((await run(exit(0, "  closed: call-1  "))).state).toBe("delivered");
    expect(h.calls.filter((call) => call.kind === "note")).toHaveLength(1);
  });

  it("retries a remote transport failure by replaying the same line", async () => {
    const h = harness();
    h.script("answer", exit(255, "", "ssh died"), exit(0, "closed: call-far"));
    const write = sent(
      actions.answer(h.context, input({ home: "far1", task: "call-far" }), "browser"),
    );
    await settled(write, "delivered");
    const answers = h.calls.filter((call) => call.kind === "answer");
    expect(answers).toHaveLength(2);
    expect(answers[0]).toEqual(answers[1]);
  });

  it("does not answer again when only the notice has to be retried", async () => {
    const h = harness();
    h.script("answer", exit(0, "closed: call-1"));
    h.script("note", exit(3), OK);
    const write = sent(actions.answer(h.context, input(), "browser"));
    await settled(write, "delivered");
    expect(h.calls.map((call) => call.kind)).toEqual(["answer", "note", "note"]);
  });

  it("refuses a missing hold, an unknown home, and answers that are not one clean line", () => {
    const h = harness();
    expect(refused(actions.answer(h.context, input({ task: "nope" }), "browser"))).toContain(
      "main/nope 沒有等你回答的待決事項",
    );
    expect(refused(actions.answer(h.context, input({ home: "down" }), "browser"))).toContain(
      "down/call-1 沒有等你回答的待決事項",
    );
    expect(refused(actions.answer(h.context, input({ home: "nobody" }), "browser"))).toBe(
      "不認得 home nobody。",
    );
    expect(refused(actions.answer(h.context, input({ home: "sm1" }), "browser"))).toContain(
      "sm1/call-1",
    );
    expect(refused(actions.answer(h.context, input({ task: "bad id" }), "browser"))).toContain(
      "格式不對",
    );
    for (const answer of ["", "  ", "a\tb", "a\nb", "a\rb", "x".repeat(1001)]) {
      expect(refused(actions.answer(h.context, input({ answer }), "browser"))).toContain("答案");
    }
    expect(refused(actions.answer(h.context, input({ label: "a\tb" }), "browser"))).toContain(
      "選項",
    );
    expect(actions.answer(h.context, input({ answer: "x".repeat(1000) }), "browser").ok).toBe(true);
    expect(actions.ANSWER_MODES).toEqual(["done", "release"]);
  });
});

describe("tagAgent", () => {
  it("tags in the home the task lives in, recording the tag it saw", async () => {
    const h = harness();
    const main = sent(actions.tagAgent(h.context, "main", "tagged", "old", "browser"));
    const local = sent(actions.tagAgent(h.context, "sm1", "sm-loose", "login", "browser"));
    const remote = sent(actions.tagAgent(h.context, "far1", "far-loose", "login", "browser"));
    await settled(remote, "delivered");
    await settled(local, "delivered");
    await settled(main, "delivered");
    expect(main).toMatchObject({
      topic: "billing",
      text: "歸到「Billing」",
      plan: {
        type: "tag",
        placement: "main",
        task: "tagged",
        topic: "billing",
        lastLineAtSend: "billing T2",
      },
    });
    expect(local.plan).toMatchObject({ placement: "local", lastLineAtSend: "" });
    expect(h.calls).toContainEqual({
      kind: "tag",
      placement: "main",
      task: "tagged",
      topic: "billing",
    });
    expect(h.calls).toContainEqual({
      kind: "tag",
      placement: "local",
      secondmate: "sm1",
      task: "sm-loose",
      topic: "login",
    });
    expect(h.calls).toContainEqual({
      kind: "tag",
      placement: "remote",
      secondmate: "far1",
      task: "far-loose",
      topic: "login",
    });
    expect(h.delivered).toHaveLength(3);
  });

  it("refuses topics that are not confirmed, unknown homes, and bad task ids", () => {
    const h = harness();
    expect(sent(actions.tagAgent(h.context, "down", "t", "login", "browser")).plan).toMatchObject({
      placement: "remote",
      lastLineAtSend: "",
    });
    for (const topic of ["idea", "gone", "nope"]) {
      expect(refused(actions.tagAgent(h.context, "main", "t", topic, "browser"))).toBe(
        `${topic} 不是已確認的議題。`,
      );
    }
    expect(refused(actions.tagAgent(h.context, "nobody", "t", "login", "browser"))).toBe(
      "不認得 home nobody。",
    );
    expect(refused(actions.tagAgent(h.context, "main", "a b", "login", "browser"))).toContain(
      "格式不對",
    );
  });

  it("reconciles against a fresh read before every retry", async () => {
    const h = harness();
    const tag = (task: string): WriteRecord =>
      sent(actions.tagAgent(h.context, "far1", task, "login", "browser"));
    const count = (task: string): number =>
      h.calls.filter((call) => call.kind === "tag" && call.task === task).length;

    h.script("tag", exit(255, "", "ssh died"));
    h.tags.set("far1/landed", "billing T0\nlogin T1");
    const landed = tag("landed");
    await settled(landed, "delivered");
    expect(count("landed")).toBe(1);

    h.script("tag", exit(255));
    h.tags.set("far1/taken", "billing T9");
    const taken = tag("taken");
    await settled(taken, "handled_elsewhere");
    expect(count("taken")).toBe(1);

    h.script("tag", exit(255), OK);
    const unchanged = tag("unchanged");
    await settled(unchanged, "delivered");
    expect(count("unchanged")).toBe(2);

    h.script("tag", exit(255), exit(255), exit(255));
    h.tags.set("far1/unreachable", null);
    const unreachable = tag("unreachable");
    await settled(unreachable, "undelivered");
    expect(unreachable.error).toBe("對帳時讀不到那個 home。");
    expect(count("unreachable")).toBe(1);

    h.script("tag", exit(255, "", "main cannot be unreachable"), exit(1, "", "refused"));
    const local = sent(actions.tagAgent(h.context, "main", "x", "login", "browser"));
    await settled(local, "failed");
    expect(local.error).toBe("main cannot be unreachable");
  });
});

describe("resend and ignore", () => {
  it("resends a failed write under the same id and ignores on request", async () => {
    const h = harness();
    h.script("send", exit(1, "", "no such task"));
    const write = sent(actions.direct(h.context, "main", "t", "hi", "browser"));
    await settled(write, "failed");
    expect(h.engine.resend(write.id, false)).toBeNull();
    await settled(write, "delivered");
    expect(write.error).toBeNull();
    expect(h.audit().map((line) => line["state"])).toEqual([
      "sending",
      "failed",
      "sending",
      "delivered",
    ]);
    expect(h.engine.resend(write.id, false)).toBe("這筆寫入不需要重送。");
    expect(h.engine.ignore(write.id)).toBe("這筆寫入不需要忽略。");
    expect(h.engine.resend("nope", true)).toBe("沒有這筆寫入。");
    expect(h.engine.ignore("nope")).toBe("沒有這筆寫入。");

    h.script("send", exit(1));
    const dropped = sent(actions.direct(h.context, "main", "t", "bye", "browser"));
    await settled(dropped, "failed");
    expect(h.engine.ignore(dropped.id)).toBeNull();
    expect(dropped.state).toBe("ignored");
    expect(h.engine.resend(dropped.id, true)).toBe("這筆寫入不需要重送。");
  });

  it("resets the retry count on a resend and reconciles a resent tag first", async () => {
    const h = harness();
    h.script("note", exit(3), exit(3), exit(3));
    const note = sent(actions.message(h.context, "billing", "a", "browser"));
    await settled(note, "undelivered");
    expect(note.attempt).toBe(2);
    expect(h.engine.resend(note.id, false)).toBeNull();
    expect(note.attempt).toBe(0);
    await settled(note, "delivered");

    h.script("tag", exit(1, "", "refused"));
    const tag = sent(actions.tagAgent(h.context, "main", "t", "login", "browser"));
    await settled(tag, "failed");
    h.tags.set("main/t", "login T5");
    h.engine.resend(tag.id, false);
    await settled(tag, "delivered");
    expect(h.calls.filter((call) => call.kind === "tag")).toHaveLength(1);
  });
});

describe("restart", () => {
  it("knows which writes are safe to repeat", () => {
    expect(isDedupable({ type: "note", requestId: "r", body: "b" })).toBe(true);
    expect(isDedupable({ type: "send", task: "t" })).toBe(false);
    expect(isDedupable({ type: "relay", secondmate: "s", remote: true, deliveryId: "d" })).toBe(
      true,
    );
    expect(isDedupable({ type: "relay", secondmate: "s", remote: false, deliveryId: "d" })).toBe(
      false,
    );
    expect(
      isDedupable({
        type: "answer",
        placement: "local",
        line: "l",
        noteBody: "n",
        answered: false,
      }),
    ).toBe(true);
    expect(
      isDedupable({ type: "tag", placement: "main", task: "t", topic: "x", lastLineAtSend: "" }),
    ).toBe(true);
  });

  it("continues a safe write, flags an unsafe one, and expires an old one", async () => {
    const slow = { retryDelaysMs: [60_000, 60_000] };
    const h = harness(slow);
    h.script("note", exit(3));
    h.script("answer", exit(0, "closed: call-1"));
    const note = sent(actions.message(h.context, "billing", "resume me", "browser"));
    await settled(note, "retrying");
    h.script("note", exit(3));
    const answered = sent(
      actions.answer(
        h.context,
        { home: "main", task: "call-1", answer: "好", label: "好", mode: "done" },
        "browser",
      ),
    );
    await settled(answered, "retrying");
    h.script("answer", exit(255, "", "ssh died"));
    const unanswered = sent(
      actions.answer(
        h.context,
        { home: "far1", task: "call-far", answer: "好", label: "好", mode: "done" },
        "browser",
      ),
    );
    await settled(unanswered, "retrying");
    h.script("tag", exit(255));
    const tagged = sent(actions.tagAgent(h.context, "far1", "far-loose", "login", "browser"));
    await settled(tagged, "retrying");
    const hanging = new Promise<CommandResult>(() => undefined);
    h.script("send", hanging as unknown as CommandResult);
    const send = sent(actions.direct(h.context, "main", "t", "mid-flight", "browser"));
    const relayLocal = sent(actions.direct(h.context, "sm1", "t", "mid-flight too", "browser"));
    void relayLocal;

    const after = h.restart({ retryDelaysMs: [5, 5] });
    expect(after.engine.records.get(note.id)).toMatchObject({
      state: "retrying",
      attempt: 1,
      text: "resume me",
    });
    after.tags.set("far1/far-loose", "login T9");
    after.script("answer", exit(0, "closed: call-far"));
    await after.engine.resumeUnfinished();
    const resumed = after.engine.records.get(note.id) as WriteRecord;
    await settled(resumed, "delivered");
    await settled(after.engine.records.get(answered.id) as WriteRecord, "delivered");
    await settled(after.engine.records.get(unanswered.id) as WriteRecord, "delivered");
    await settled(after.engine.records.get(tagged.id) as WriteRecord, "delivered");
    // The hold answered before the restart is not answered again; the one that never landed is.
    // The tag that turned out to be in place is not written again.
    expect(after.calls.map((call) => call.kind).toSorted()).toEqual([
      "answer",
      "note",
      "note",
      "note",
    ]);
    expect(after.calls).toContainEqual({
      kind: "note",
      requestId: `tb-${answered.id}-note`,
      body: expect.stringContaining("main/call-1：好"),
    });
    expect(after.engine.records.get(send.id)).toMatchObject({
      state: "unknown",
      error: expect.stringContaining("重啟"),
    });
    expect(after.engine.resend(send.id, false)).toContain("需要先確認");
    expect(after.engine.resend(send.id, true)).toBeNull();
    await settled(after.engine.records.get(send.id) as WriteRecord, "delivered");

    const again = after.restart();
    await again.engine.resumeUnfinished();
    expect(again.calls).toEqual([]);
    expect(again.engine.records.get(note.id)?.state).toBe("delivered");
  });

  it("does not send a write older than the resume window", async () => {
    const h = harness({ retryDelaysMs: [60_000] });
    h.script("note", exit(3));
    const note = sent(actions.message(h.context, "billing", "stale", "browser"));
    await settled(note, "retrying");
    await new Promise((resolve) => setTimeout(resolve, 30));
    const after = h.restart({ resumeWindowMs: 10 });
    await after.engine.resumeUnfinished();
    expect(after.engine.records.get(note.id)).toMatchObject({
      state: "undelivered",
      error: expect.stringContaining("放太久"),
    });
    expect(after.calls).toEqual([]);
    const fresh = h.restart({ resumeWindowMs: 60_000 });
    expect(fresh.engine.records.get(note.id)?.state).toBe("undelivered");
  });

  it("still resumes a write exactly as old as the resume window", async () => {
    const file = path.join(dir, "aged.jsonl");
    const now = Date.parse("2026-11-16T00:00:00Z");
    const record = {
      id: "w-aged",
      channel: "browser",
      home: "main",
      task: null,
      topic: "billing",
      text: "x",
      plan: { type: "note", requestId: "r-aged", body: "b" },
      state: "sending",
      attempt: 0,
      error: null,
      nextAt: null,
      createdAt: now - 1000,
    };
    fs.writeFileSync(
      file,
      `${JSON.stringify({ ts: "t", write_id: "w-aged", state: "sending", attempt: 0, sending: record })}\n`,
    );
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(now);
    try {
      const h = harness({ resumeWindowMs: 1000 }, file);
      await h.engine.resumeUnfinished();
      expect(h.engine.records.get("w-aged")?.state).not.toBe("undelivered");
      vi.useRealTimers();
      await settled(h.engine.records.get("w-aged") as WriteRecord, "delivered");
      expect(h.calls).toEqual([{ kind: "note", requestId: "r-aged", body: "b" }]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("ignores audit lines that are not about a write", async () => {
    const h = harness();
    const write = sent(actions.message(h.context, "billing", "x", "browser"));
    await settled(write, "delivered");
    fs.appendFileSync(
      path.join(dir, "audit.jsonl"),
      `junk\n[1]\n${JSON.stringify({ rejected: "origin", host: "x" })}\n${JSON.stringify({ write_id: "ghost", state: "failed" })}\n${JSON.stringify({ write_id: write.id })}\nhalf`,
    );
    const after = h.restart();
    expect([...after.engine.records.keys()]).toEqual([write.id]);
    expect(after.engine.records.get(write.id)?.state).toBe("delivered");
  });
});

describe("serialization", () => {
  it("runs one command per home at a time without holding the queue during a retry wait", async () => {
    const h = harness({ retryDelaysMs: [80] });
    let running = 0;
    let peak = 0;
    const order: string[] = [];
    const engine = new WriteEngine(
      path.join(dir, "serial.jsonl"),
      {
        run: async (command) => {
          running += 1;
          peak = Math.max(peak, running);
          order.push(command.kind === "note" ? command.body : command.kind);
          await new Promise((resolve) => setTimeout(resolve, 15));
          running -= 1;
          return command.kind === "note" &&
            command.body.endsWith("retry me") &&
            order.filter((entry) => entry.endsWith("retry me")).length === 1
            ? exit(3)
            : OK;
        },
        secondmates: () => SECONDMATES,
        readTags: async () => "",
        prepare: async () => undefined,
        onChange: () => undefined,
        onDelivered: () => undefined,
      },
      { retryDelaysMs: [80], resumeWindowMs: 1000, commandTimeoutMs: 1000 },
    );
    open.push(engine);
    const context = { ...h.context, writes: engine };
    const first = sent(actions.message(context, "billing", "retry me", "browser"));
    const second = sent(actions.message(context, "billing", "second", "browser"));
    const third = sent(actions.message(context, "billing", "third", "browser"));
    await settled(third, "delivered");
    expect(first.state).toBe("retrying");
    expect(second.state).toBe("delivered");
    await settled(first, "delivered");
    expect(peak).toBe(1);
    expect(order.map((entry) => entry.split("\n")[1])).toEqual([
      "retry me",
      "second",
      "third",
      "retry me",
    ]);
  });
});

function api(
  h: Harness,
  overrides: { topicOp?: (op: string, args: Record<string, unknown>) => BoardResponse } = {},
) {
  const confirm = new ConfirmStore();
  const seen: string[] = [];
  let version = "1-0";
  const handler: ApiHandler = createApi({
    bootId: "boot",
    version: () => version,
    view: () => ({ boot_id: "boot", version, queues: {} }),
    touch: () => seen.push("touch"),
    refresh: async () => {
      seen.push("refresh");
    },
    topicOp:
      overrides.topicOp ??
      ((op, args) => {
        seen.push(`${op}:${JSON.stringify(args)}`);
        return { ok: true, line: `ok ${op}` };
      }),
    actionContext: () => h.context,
    writes: h.engine,
    confirm,
  });
  const call = (route: string, body: Record<string, unknown> = {}, query = "") =>
    handler(
      route.startsWith("GET ") ? "GET" : "POST",
      route.replace(/^(GET|POST) /, ""),
      new URLSearchParams(query),
      body,
    );
  return { call, seen, bump: () => (version = "2-0") };
}

describe("api", () => {
  it("answers state with a full view only when the version differs", async () => {
    const h = harness();
    const { call, seen, bump } = api(h);
    expect(await call("GET state")).toEqual({
      status: 200,
      body: { ok: true, changed: true, boot_id: "boot", version: "1-0", queues: {} },
    });
    expect(await call("GET state", {}, "v=boot:1-0")).toEqual({
      status: 200,
      body: { ok: true, changed: false },
    });
    expect((await call("GET state", {}, "v=other:1-0")).body["changed"]).toBe(true);
    bump();
    expect((await call("GET state", {}, "v=boot:1-0")).body["changed"]).toBe(true);
    expect(seen).toEqual(["touch", "touch", "touch", "touch"]);
    expect(await call("POST refresh")).toEqual({ status: 200, body: { ok: true } });
    expect(seen.slice(-2)).toEqual(["touch", "refresh"]);
    expect(await call("GET nope")).toEqual({
      status: 404,
      body: { error: "not-found", message: "沒有這個 API。" },
    });
    expect((await call("POST state")).status).toBe(404);
  });

  it("passes topic routes to the topic operation of the same name", async () => {
    const h = harness();
    const { call, seen } = api(h);
    for (const op of ["confirm", "rename", "goal", "archive", "reopen", "keep"]) {
      expect(await call(`POST topics/${op}`, { id: "a", value: "v" })).toEqual({
        status: 200,
        body: { ok: true, line: `ok ${op}` },
      });
    }
    await call("POST topics/move", { id: "a", queue: "high" });
    await call("POST topics/move", { id: "a", queue: "high", before: "b" });
    expect(seen.slice(-2)).toEqual([
      'move:{"id":"a","queue":"high","last":true}',
      'move:{"id":"a","queue":"high","before":"b"}',
    ]);
    expect((await call("POST topics/propose", { name: "x" })).status).toBe(404);
    const refusing = api(h, { topicOp: () => ({ ok: false, code: "refused", line: "不行" }) });
    expect(await refusing.call("POST topics/rename", {})).toEqual({
      status: 409,
      body: { error: "refused", message: "不行" },
    });
    const malformed = api(h, { topicOp: () => ({ ok: false, code: "usage", line: "用法錯" }) });
    expect(await malformed.call("POST topics/rename", {})).toEqual({
      status: 400,
      body: { error: "usage", message: "用法錯" },
    });
  });

  it("merges only on the second request, with a code bound to that merge", async () => {
    const h = harness();
    const { call, seen } = api(h);
    const first = await call("POST topics/merge", { from: "a", into: "b" });
    expect(first.body).toMatchObject({
      ok: true,
      confirm: expect.stringMatching(/^[0-9a-f]{32}$/),
      expires_at: expect.any(Number),
    });
    expect(seen).toEqual([]);
    const code = first.body["confirm"];
    expect(
      (await call("POST topics/merge", { from: "a", into: "c", confirm: code })).body["error"],
    ).toBe("confirm");
    expect((await call("POST topics/merge", { from: "a", into: "b", confirm: code })).status).toBe(
      409,
    );
    const again = (await call("POST topics/merge", { from: "a", into: "b" })).body["confirm"];
    expect(
      (await call("POST topics/merge", { from: "a", into: "b", confirm: 5 })).body["error"],
    ).toBe("confirm");
    expect(await call("POST topics/merge", { from: "a", into: "b", confirm: again })).toEqual({
      status: 200,
      body: { ok: true, line: "ok merge" },
    });
    expect(seen).toEqual(['merge:{"from":"a","into":"b"}']);
  });

  it("answers a hold only on the second request, with a mode", async () => {
    const h = harness();
    h.script("answer", exit(0, "closed: call-1"));
    const { call } = api(h);
    const body = { home: "main", task: "call-1", answer: "合併", label: "合併" };
    const code = (await call("POST holds/answer", body)).body["confirm"];
    expect(h.calls).toEqual([]);
    expect(await call("POST holds/answer", { ...body, confirm: code })).toEqual({
      status: 400,
      body: { error: "usage", message: "要選「這件事結束」或「讓工作繼續」。" },
    });
    const other = (await call("POST holds/answer", body)).body["confirm"];
    expect(
      (await call("POST holds/answer", { ...body, answer: "先不要", confirm: other, mode: "done" }))
        .body["error"],
    ).toBe("confirm");
    const changed = (await call("POST holds/answer", body)).body["confirm"];
    const firstHold = h.context.homes[0]?.report?.holds[0];
    if (firstHold === undefined) throw new Error("the fixture has no hold");
    firstHold.question = "a different question";
    expect(
      (await call("POST holds/answer", { ...body, confirm: changed, mode: "done" })).body["error"],
    ).toBe("confirm");
    const good = (await call("POST holds/answer", body)).body["confirm"];
    const done = await call("POST holds/answer", { ...body, confirm: good, mode: "release" });
    expect(done).toEqual({
      status: 200,
      body: { ok: true, write_id: expect.stringMatching(/^w-/) },
    });
    await vi.waitFor(() =>
      expect(h.calls[0]).toEqual({
        kind: "answer",
        placement: "main",
        line: "call-1\t合併\t合併\trelease",
      }),
    );
    expect(h.engine.records.get(String(done.body["write_id"]))?.channel).toBe("browser");
    expect(await call("POST holds/answer", { ...body, task: "nope" })).toEqual({
      status: 409,
      body: { error: "refused", message: "這個待決事項已經不在了（可能已經有人答了）。" },
    });
    expect((await call("POST holds/answer", { ...body, home: "nobody" })).status).toBe(409);
    const tabbed = (await call("POST holds/answer", { ...body, answer: "a\tb" })).body["confirm"];
    expect(
      (await call("POST holds/answer", { ...body, answer: "a\tb", confirm: tabbed, mode: "done" }))
        .status,
    ).toBe(409);
  });

  it("sends messages, direct messages, and tags as browser writes", async () => {
    const h = harness();
    const { call } = api(h);
    const message = await call("POST messages", { topic: "billing", text: "hi" });
    const direct = await call("POST direct", { home: "main", task: "ship-a", text: "look" });
    const tag = await call("POST agents/tag", { home: "main", task: "loose", topic: "login" });
    for (const reply of [message, direct, tag]) {
      expect(reply.status).toBe(200);
      expect(h.engine.records.get(String(reply.body["write_id"]))?.channel).toBe("browser");
    }
    await vi.waitFor(() =>
      expect(h.calls.map((entry) => entry.kind).toSorted()).toEqual(["note", "send", "tag"]),
    );
    expect(await call("POST messages", { topic: "nope", text: "hi" })).toEqual({
      status: 409,
      body: { error: "refused", message: "沒有 nope 這個議題。" },
    });
    expect((await call("POST direct", { home: "main", task: "t", text: "/x" })).status).toBe(409);
    expect((await call("POST agents/tag", { home: "main", task: "t", topic: 5 })).status).toBe(409);
    expect((await call("POST messages", {})).status).toBe(409);
  });

  it("resends in one step, or two when the outcome is unknown, and ignores", async () => {
    const h = harness();
    const { call } = api(h);
    h.script("send", exit(1));
    const failed = sent(actions.direct(h.context, "main", "t", "x", "browser"));
    await settled(failed, "failed");
    expect(await call("POST writes/resend", { write_id: failed.id })).toEqual({
      status: 200,
      body: { ok: true },
    });
    await settled(failed, "delivered");
    expect(await call("POST writes/resend", { write_id: failed.id })).toEqual({
      status: 409,
      body: { error: "refused", message: "這筆寫入不需要重送。" },
    });
    expect((await call("POST writes/resend", { write_id: "nope" })).status).toBe(409);
    expect((await call("POST writes/ignore", { write_id: failed.id })).status).toBe(409);

    failed.state = "unknown";
    const first = await call("POST writes/resend", { write_id: failed.id });
    expect(first.body).toMatchObject({ ok: true, confirm: expect.any(String) });
    expect(failed.state).toBe("unknown");
    expect(
      (await call("POST writes/resend", { write_id: failed.id, confirm: "wrong" })).body["error"],
    ).toBe("confirm");
    const code = (await call("POST writes/resend", { write_id: failed.id })).body["confirm"];
    expect(await call("POST writes/resend", { write_id: failed.id, confirm: code })).toEqual({
      status: 200,
      body: { ok: true },
    });
    await settled(failed, "delivered");

    failed.state = "failed";
    expect(await call("POST writes/ignore", { write_id: failed.id })).toEqual({
      status: 200,
      body: { ok: true },
    });
    expect(failed.state).toBe("ignored");
  });
});
