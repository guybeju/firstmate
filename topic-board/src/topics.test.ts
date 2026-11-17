import { describe, expect, it } from "vitest";
import * as topics from "./topics.js";
import type { TopicResult, TopicState } from "./topics.js";

const NOW = "2026-11-16T00:00:00Z";

function done(result: TopicResult): Extract<TopicResult, { ok: true }> {
  if (!result.ok) throw new Error(`refused: ${result.line}`);
  return result;
}

function refusal(result: TopicResult): string {
  if (result.ok) throw new Error(`expected a refusal, got: ${result.line}`);
  return result.line;
}

/** A state with confirmed topics a (high), b and c (normal), d (later), and proposed p. */
function fixture(): TopicState {
  let state = topics.emptyState();
  for (const [id, queue] of [
    ["a", "high"],
    ["b", "normal"],
    ["c", "normal"],
    ["d", "later"],
  ] as const) {
    state = done(
      topics.propose(
        state,
        { name: id.toUpperCase(), goal: `goal ${id}`, id, by: "firstmate" },
        NOW,
      ),
    ).state;
    state = done(topics.confirm(state, id, queue)).state;
  }
  return done(topics.propose(state, { name: "P", goal: "goal p", id: "p", by: "firstmate" }, NOW))
    .state;
}

describe("propose", () => {
  it("stores a proposed topic outside every queue and prints its id", () => {
    const result = done(
      topics.propose(
        topics.emptyState(),
        { name: " Billing rework ", goal: "move it", by: "firstmate", queue: "high" },
        NOW,
      ),
    );
    expect(result.line).toBe("ok billing-rework 已提議，等使用者確認");
    expect(result.changed).toBe(true);
    expect(result.state.doc.topics["billing-rework"]).toEqual({
      name: "Billing rework",
      goal: "move it",
      status: "proposed",
      created_at: NOW,
      proposed_by: "firstmate",
      suggested_queue: "high",
    });
    expect(result.state.doc.queues).toEqual({ high: [], normal: [], later: [] });
  });

  it("returns the same id for an identical proposal and numbers a different goal", () => {
    const first = done(
      topics.propose(topics.emptyState(), { name: "X", goal: "one", by: "firstmate" }, NOW),
    );
    const again = done(
      topics.propose(first.state, { name: "X", goal: "one", by: "firstmate" }, NOW),
    );
    expect(again.changed).toBe(false);
    expect(again.line).toContain("ok x ");
    expect(again.state).toBe(first.state);
    const other = done(
      topics.propose(first.state, { name: "X", goal: "two", by: "firstmate" }, NOW),
    );
    expect(other.line).toContain("ok x-2 ");
    const third = done(
      topics.propose(other.state, { name: "X", goal: "three", by: "firstmate" }, NOW),
    );
    expect(third.line).toContain("ok x-3 ");
  });

  it("mints t<n> for a name with no slug and never hands out a used number", () => {
    const first = done(
      topics.propose(topics.emptyState(), { name: "帳務", goal: "g", by: "firstmate" }, NOW),
    );
    expect(first.line).toContain("ok t1 ");
    expect(first.state.doc.next_seq).toBe(2);
    const taken = done(
      topics.propose(first.state, { name: "手動", goal: "g", id: "t2", by: "firstmate" }, NOW),
    );
    const next = done(
      topics.propose(taken.state, { name: "登入", goal: "g", by: "firstmate" }, NOW),
    );
    expect(next.line).toContain("ok t3 ");
    expect(next.state.doc.next_seq).toBe(4);
  });

  it("refuses bad names, goals, and ids", () => {
    const state = fixture();
    const propose = (input: Partial<topics.ProposeInput>): TopicResult =>
      topics.propose(state, { name: "N", goal: "g", by: "firstmate", ...input }, NOW);
    expect(refusal(propose({ name: "   " }))).toContain("名稱");
    expect(refusal(propose({ name: "x".repeat(topics.NAME_MAX + 1) }))).toContain("名稱");
    expect(propose({ name: "x".repeat(topics.NAME_MAX) }).ok).toBe(true);
    expect(refusal(propose({ goal: "two\nlines" }))).toContain("目標");
    expect(refusal(propose({ goal: "x".repeat(topics.GOAL_MAX + 1) }))).toContain("目標");
    for (const hidden of [
      "a\tb",
      "a\u001b[31mb",
      "a\u0007b",
      "a\u007fb",
      "a\u0085b",
      "a\u202eb",
      "a\u2066b",
    ]) {
      expect(refusal(propose({ name: hidden }))).toContain("名稱");
      expect(refusal(propose({ goal: hidden }))).toContain("目標");
      expect(refusal(topics.rename(state, "a", hidden, NOW))).toContain("名稱");
    }
    expect(propose({ name: "帳務 重構 😀 (v2) “quoted”", goal: "é ü ñ — ok" }).ok).toBe(true);
    for (const builtin of ["constructor", "__proto__", "toString"]) {
      expect(refusal(propose({ id: builtin }))).toContain("格式");
    }
    expect(refusal(propose({ id: "-lead" }))).toContain("格式");
    expect(refusal(propose({ id: ".hidden" }))).toContain("格式");
    expect(refusal(propose({ id: "has space" }))).toContain("格式");
    expect(refusal(propose({ id: "x".repeat(65) }))).toContain("格式");
    expect(refusal(propose({ id: "a" }))).toContain("已經用過");
    expect(propose({ id: "ok.id-1_x" }).ok).toBe(true);
  });

  it("counts characters, not UTF-16 units, against the limits", () => {
    const name = "𝒳".repeat(topics.NAME_MAX);
    expect(topics.propose(topics.emptyState(), { name, goal: "g", by: "firstmate" }, NOW).ok).toBe(
      true,
    );
  });
});

describe("confirm", () => {
  it("queues a proposal at the end of the chosen, suggested, or normal queue", () => {
    const state = fixture();
    const byDefault = done(topics.confirm(state, "p", undefined));
    expect(byDefault.state.doc.queues.normal).toEqual(["b", "c", "p"]);
    expect(byDefault.state.doc.topics["p"]?.status).toBe("confirmed");
    expect(byDefault.events).toEqual([
      { kind: "topic.confirmed", topic: "p", text: "議題「P」已確認，放進「一般」" },
    ]);
    expect(done(topics.confirm(state, "p", "later")).state.doc.queues.later).toEqual(["d", "p"]);
    const suggested = done(
      topics.propose(state, { name: "S", goal: "g", id: "s", queue: "high", by: "firstmate" }, NOW),
    );
    expect(done(topics.confirm(suggested.state, "s", undefined)).state.doc.queues.high).toEqual([
      "a",
      "s",
    ]);
    expect(done(topics.confirm(suggested.state, "s", "later")).line).toBe(
      "ok s 已確認，放進「待辦」",
    );
  });

  it("is a no-op when repeated and refuses unknown or archived topics", () => {
    const state = fixture();
    const again = done(topics.confirm(state, "a", "later"));
    expect(again.changed).toBe(false);
    expect(again.state).toBe(state);
    expect(refusal(topics.confirm(state, "nope", undefined))).toContain("沒有 nope");
    const archived = done(topics.archive(state, "a", NOW)).state;
    expect(refusal(topics.confirm(archived, "a", undefined))).toContain("已封存");
  });
});

describe("move", () => {
  const order = (state: TopicState): string =>
    topics.QUEUES.map((queue) => `${queue}:${state.doc.queues[queue].join(",")}`).join(" ");

  it("appends to another queue and reports a topic leaving later", () => {
    const state = fixture();
    const moved = done(topics.move(state, "d", "normal", undefined));
    expect(order(moved.state)).toBe("high:a normal:b,c,d later:");
    expect(moved.dispatchable).toEqual(["d"]);
    expect(moved.line).toBe("ok d 已移到「一般」");
    expect(done(topics.move(state, "a", "normal", undefined)).dispatchable).toEqual([]);
    expect(done(topics.move(state, "a", "later", undefined)).dispatchable).toEqual([]);
    expect(order(done(topics.move(state, "a", "later", undefined)).state)).toBe(
      "high: normal:b,c later:d,a",
    );
  });

  it("places a topic first, last, or before another", () => {
    const state = fixture();
    expect(order(done(topics.move(state, "c", "normal", { first: true })).state)).toBe(
      "high:a normal:c,b later:d",
    );
    expect(order(done(topics.move(state, "b", "normal", { last: true })).state)).toBe(
      "high:a normal:c,b later:d",
    );
    expect(order(done(topics.move(state, "d", "normal", { before: "c" })).state)).toBe(
      "high:a normal:b,d,c later:",
    );
    expect(order(done(topics.move(state, "d", "normal", { first: true })).state)).toBe(
      "high:a normal:d,b,c later:",
    );
    expect(order(done(topics.move(state, "a", "normal", { before: "b" })).state)).toBe(
      "high: normal:a,b,c later:d",
    );
  });

  it("leaves the order alone when nothing would change", () => {
    const state = fixture();
    for (const position of [undefined, { last: true }, { before: "c" }] as const) {
      const result = done(
        topics.move(state, "b", "normal", position === undefined ? undefined : { ...position }),
      );
      if (position !== undefined && "last" in position) continue;
      expect(result.changed).toBe(false);
      expect(result.state).toBe(state);
    }
    expect(done(topics.move(state, "c", "normal", { last: true })).changed).toBe(false);
    expect(done(topics.move(state, "b", "normal", { first: true })).changed).toBe(false);
  });

  it("refuses a bad anchor, a proposal, and an unknown topic", () => {
    const state = fixture();
    expect(refusal(topics.move(state, "b", "normal", { before: "a" }))).toContain("不在那個佇列");
    expect(refusal(topics.move(state, "b", "normal", { before: "b" }))).toContain("不在那個佇列");
    expect(refusal(topics.move(state, "p", "normal", undefined))).toContain("提議中");
    expect(refusal(topics.move(state, "nope", "normal", undefined))).toContain("沒有 nope");
  });
});

describe("rename, goal, and close-propose", () => {
  it("stores trimmed text and treats the same text as no change", () => {
    const state = fixture();
    const renamed = done(topics.rename(state, "a", "  New  ", NOW));
    expect(renamed.state.doc.topics["a"]?.name).toBe("New");
    expect(renamed.line).toBe("ok a 名稱已改");
    expect(done(topics.rename(renamed.state, "a", "New", NOW)).changed).toBe(false);
    const goal = done(topics.setGoal(state, "p", "fresh goal"));
    expect(goal.state.doc.topics["p"]?.goal).toBe("fresh goal");
    expect(goal.line).toBe("ok p 目標已改");
    expect(refusal(topics.rename(state, "a", "", NOW))).toContain("名稱");
    expect(refusal(topics.rename(state, "a", "x".repeat(topics.NAME_MAX + 1), NOW))).toContain(
      "名稱",
    );
    expect(topics.setGoal(state, "a", "x".repeat(topics.NAME_MAX + 1)).ok).toBe(true);
    expect(refusal(topics.setGoal(state, "a", "x".repeat(topics.GOAL_MAX + 1)))).toContain("目標");
    expect(refusal(topics.setGoal(state, "nope", "g"))).toContain("沒有 nope");
  });

  it("records, replaces, and clears a close proposal", () => {
    const state = fixture();
    const proposed = done(topics.closePropose(state, "a", " all merged ", NOW));
    expect(proposed.state.doc.topics["a"]?.close_proposal).toEqual({
      at: NOW,
      reason: "all merged",
    });
    expect(proposed.events[0]).toEqual({
      kind: "topic.close_proposed",
      topic: "a",
      text: "first mate 提議關閉：all merged",
    });
    expect(done(topics.closePropose(proposed.state, "a", "all merged", "later")).changed).toBe(
      false,
    );
    const replaced = done(topics.closePropose(proposed.state, "a", "other", "later"));
    expect(replaced.state.doc.topics["a"]?.close_proposal).toEqual({
      at: "later",
      reason: "other",
    });
    expect(refusal(topics.closePropose(state, "p", "x", NOW))).toContain("提議中");
    expect(refusal(topics.closePropose(state, "a", "  ", NOW))).toContain("理由");
    const kept = done(topics.keepOpen(proposed.state, "a"));
    expect(kept.state.doc.topics["a"]?.close_proposal).toBeUndefined();
    expect(kept.line).toBe("ok a 先不關");
    expect(done(topics.keepOpen(state, "a")).changed).toBe(false);
    expect(refusal(topics.keepOpen(state, "nope"))).toContain("沒有 nope");
  });
});

describe("archive and reopen", () => {
  it("moves a topic to the archive without its close proposal, and back", () => {
    const withClose = done(topics.closePropose(fixture(), "b", "done", NOW)).state;
    const archived = done(topics.archive(withClose, "b", "T1"));
    expect(archived.state.doc.topics["b"]).toBeUndefined();
    expect(archived.state.doc.queues.normal).toEqual(["c"]);
    expect(archived.state.archive.topics["b"]).toEqual({
      name: "B",
      goal: "goal b",
      status: "confirmed",
      created_at: NOW,
      proposed_by: "firstmate",
      archived_at: "T1",
    });
    expect(archived.events[0]?.kind).toBe("topic.archived");
    expect(done(topics.archive(archived.state, "b", "T2")).changed).toBe(false);

    const reopened = done(topics.reopen(archived.state, "b", undefined, NOW));
    expect(reopened.state.archive.topics["b"]).toBeUndefined();
    expect(reopened.state.doc.queues.normal).toEqual(["c", "b"]);
    expect(reopened.state.doc.topics["b"]).not.toHaveProperty("archived_at");
    expect(reopened.dispatchable).toEqual(["b"]);
    expect(reopened.line).toBe("ok b 已重開，放進「一般」");
    expect(done(topics.reopen(archived.state, "b", "later", NOW)).dispatchable).toEqual([]);
    expect(done(topics.reopen(archived.state, "b", "high", NOW)).state.doc.queues.high).toEqual([
      "a",
      "b",
    ]);
    expect(done(topics.reopen(reopened.state, "b", undefined, NOW)).changed).toBe(false);
  });

  it("turns down a proposal by archiving it and accepts it on reopen", () => {
    const state = fixture();
    const dismissed = done(topics.archive(state, "p", NOW));
    expect(dismissed.state.archive.topics["p"]?.status).toBe("proposed");
    const accepted = done(topics.reopen(dismissed.state, "p", "high", NOW));
    expect(accepted.state.doc.topics["p"]?.status).toBe("confirmed");
    expect(refusal(topics.archive(state, "nope", NOW))).toContain("沒有 nope");
    expect(refusal(topics.reopen(state, "nope", undefined, NOW))).toContain("沒有 nope");
  });
});

describe("merge", () => {
  it("aliases the old id and removes the old topic", () => {
    const state = fixture();
    const merged = done(topics.merge(state, "b", "a", NOW));
    expect(merged.state.doc.merged).toEqual({ b: "a" });
    expect(merged.state.doc.topics["b"]).toBeUndefined();
    expect(merged.state.doc.queues.normal).toEqual(["c"]);
    expect(merged.events[0]).toEqual({
      kind: "topic.merged",
      topic: "a",
      text: "議題「B」已併入「A」",
    });
    expect(topics.resolveTopicId(merged.state.doc, "b")).toBe("a");
    expect(done(topics.merge(merged.state, "b", "a", NOW)).changed).toBe(false);
    expect(
      done(topics.rename(merged.state, "b", "Via alias", NOW)).state.doc.topics["a"]?.name,
    ).toBe("Via alias");
  });

  it("follows chains and merges a proposal", () => {
    const first = done(topics.merge(fixture(), "b", "a", NOW)).state;
    const second = done(topics.merge(first, "a", "c", NOW)).state;
    expect(topics.resolveTopicId(second.doc, "b")).toBe("c");
    expect(done(topics.merge(second, "p", "b", NOW)).state.doc.merged["p"]).toBe("c");
  });

  it("records merges, renames, archiving and reopening in the history, oldest first", () => {
    let state = done(topics.rename(fixture(), "b", "Bee", "2026-11-17T00:00:00Z")).state;
    state = done(topics.merge(state, "b", "a", "2026-11-18T00:00:00Z")).state;
    state = done(topics.archive(state, "c", "2026-11-19T00:00:00Z")).state;
    state = done(topics.reopen(state, "c", undefined, "2026-11-20T00:00:00Z")).state;
    expect(state.doc.history).toEqual([
      { at: "2026-11-17T00:00:00Z", kind: "renamed", topic: "b", name: "Bee", from_name: "B" },
      {
        at: "2026-11-18T00:00:00Z",
        kind: "merged",
        topic: "a",
        name: "A",
        from: "b",
        from_name: "Bee",
      },
      { at: "2026-11-19T00:00:00Z", kind: "archived", topic: "c", name: "C" },
      { at: "2026-11-20T00:00:00Z", kind: "reopened", topic: "c", name: "C" },
    ]);
  });

  it("adds nothing to the history when an operation changes nothing or is refused", () => {
    const state = fixture();
    expect(done(topics.rename(state, "a", "A", NOW)).state.doc.history).toEqual([]);
    expect(done(topics.setGoal(state, "a", "another goal")).state.doc.history).toEqual([]);
    const merged = done(topics.merge(state, "b", "a", NOW)).state;
    expect(done(topics.merge(merged, "b", "a", NOW)).state.doc.history).toHaveLength(1);
    expect(done(topics.reopen(state, "a", undefined, NOW)).state.doc.history).toEqual([]);
  });

  it("splits a new confirmed topic off, right after its source in the same queue", () => {
    const state = fixture();
    const split = done(
      topics.split(state, { from: "b", name: " Exports ", goal: "export files", id: "exp" }, NOW),
    );
    expect(split.line).toBe("ok exp 已從 b 拆出，放進「一般」");
    expect(split.state.doc.queues.normal).toEqual(["b", "exp", "c"]);
    expect(split.state.doc.topics["exp"]).toEqual({
      name: "Exports",
      goal: "export files",
      status: "confirmed",
      created_at: NOW,
      proposed_by: "user",
    });
    expect(split.state.doc.history).toEqual([
      { at: NOW, kind: "split", topic: "exp", name: "Exports", from: "b", from_name: "B" },
    ]);
    expect(split.events).toEqual([
      { kind: "topic.split", topic: "exp", text: "從議題「B」拆出「Exports」" },
    ]);
    expect(split.dispatchable).toEqual([]);
    expect(state.doc.topics["exp"]).toBeUndefined();
  });

  it("mints an id for a split when none is given, and follows a merged-away source", () => {
    const merged = done(topics.merge(fixture(), "c", "b", NOW)).state;
    const split = done(topics.split(merged, { from: "c", name: "Side work", goal: "g" }, NOW));
    expect(split.line).toBe("ok side-work 已從 b 拆出，放進「一般」");
    expect(split.state.doc.queues.normal).toEqual(["b", "side-work"]);
  });

  it("changes nothing when the same split is asked for again", () => {
    const input = { from: "b", name: "Exports", goal: "export files" };
    const once = done(topics.split(fixture(), input, NOW));
    const again = done(topics.split(once.state, input, "2026-12-01T00:00:00Z"));
    expect(again.changed).toBe(false);
    expect(again.line).toBe("ok exports 本來就已從 b 拆出");
    expect(again.state.doc.history).toHaveLength(1);
    const renamed = done(topics.rename(once.state, "exports", "Other", NOW)).state;
    expect(done(topics.split(renamed, input, NOW)).line).toBe(
      "ok exports-2 已從 b 拆出，放進「一般」",
    );
  });

  it("splits again under a new id once the earlier split-off topic is archived", () => {
    const input = { from: "b", name: "Exports", goal: "export files" };
    const once = done(topics.split(fixture(), input, NOW)).state;
    const archived = done(topics.archive(once, "exports", NOW)).state;
    const again = done(topics.split(archived, input, NOW));
    expect(again.line).toBe("ok exports-2 已從 b 拆出，放進「一般」");
    expect(again.state.doc.queues.normal).toEqual(["b", "exports-2", "c"]);
  });

  it("recognizes a split asked for again after its source was merged elsewhere", () => {
    const input = { from: "b", name: "Exports", goal: "export files" };
    const once = done(topics.split(fixture(), input, NOW)).state;
    const merged = done(topics.merge(once, "b", "c", NOW)).state;
    const again = done(topics.split(merged, input, NOW));
    expect(again.changed).toBe(false);
    expect(again.line).toBe("ok exports 本來就已從 c 拆出");
  });

  it("refuses to split a confirmed topic that sits in no queue", () => {
    const state = fixture();
    state.doc.queues.normal = ["c"];
    const line = refusal(topics.split(state, { from: "b", name: "Exports", goal: "g" }, NOW));
    expect(line).toContain("不在任何佇列");
  });

  it("refuses a split from a topic that is not confirmed, or with a bad name, goal, or id", () => {
    const state = fixture();
    const input = { from: "b", name: "Exports", goal: "g" };
    expect(refusal(topics.split(state, { ...input, from: "p" }, NOW))).toContain("提議中");
    expect(refusal(topics.split(state, { ...input, from: "nope" }, NOW))).toContain("沒有 nope");
    const archived = done(topics.archive(state, "b", NOW)).state;
    expect(refusal(topics.split(archived, input, NOW))).toContain("已封存");
    expect(refusal(topics.split(state, { ...input, name: "" }, NOW))).toContain("名稱");
    expect(refusal(topics.split(state, { ...input, goal: "a\nb" }, NOW))).toContain("目標");
    expect(refusal(topics.split(state, { ...input, id: "a" }, NOW))).toContain("a");
    expect(refusal(topics.split(state, { ...input, id: "bad id" }, NOW))).toContain("id");
  });

  it("refuses merging into itself, a proposal, an archived or an unknown topic", () => {
    const state = fixture();
    expect(refusal(topics.merge(state, "a", "a", NOW))).toContain("它自己");
    expect(refusal(topics.merge(state, "a", "p", NOW))).toContain("提議中");
    expect(refusal(topics.merge(state, "nope", "a", NOW))).toContain("沒有 nope");
    expect(refusal(topics.merge(state, "a", "nope", NOW))).toContain("沒有 nope");
    const archived = done(topics.archive(state, "b", NOW)).state;
    expect(refusal(topics.merge(archived, "a", "b", NOW))).toContain("已封存");
    expect(refusal(topics.merge(archived, "b", "a", NOW))).toContain("已封存");
    expect(
      refusal(
        topics.propose(
          done(topics.merge(state, "b", "a", NOW)).state,
          { name: "B", goal: "g", id: "b", by: "user" },
          NOW,
        ),
      ),
    ).toContain("已經用過");
  });
});

describe("helpers", () => {
  it("starts empty, at version 1, with the first sequence number", () => {
    expect(topics.emptyState()).toEqual({
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
    });
  });

  it("follows exactly 64 merge hops", () => {
    const state = topics.emptyState();
    for (let hop = 0; hop < 65; hop += 1) state.doc.merged[`n${hop}`] = `n${hop + 1}`;
    expect(topics.resolveTopicId(state.doc, "n1")).toBe("n65");
    expect(topics.resolveTopicId(state.doc, "n0")).toBe("n64");
  });

  it("keeps a minted slug short enough to take a numeric suffix", () => {
    const result = topics.propose(
      topics.emptyState(),
      { name: "x".repeat(80), goal: "g", by: "user" },
      NOW,
    );
    expect(done(result).line).toContain(`ok ${"x".repeat(60)} `);
  });

  it("recognizes queues and topic ids", () => {
    expect(topics.isQueue("high")).toBe(true);
    expect(topics.isQueue("urgent")).toBe(false);
    expect(topics.isQueue(3)).toBe(false);
    expect(topics.isValidTopicId("a.b-c_1")).toBe(true);
    expect(topics.isValidTopicId("")).toBe(false);
    expect(topics.isValidTopicId("x".repeat(64))).toBe(true);
  });

  it("stops following a merge loop", () => {
    const state = topics.emptyState();
    state.doc.merged = { a: "b", b: "a" };
    expect(["a", "b"]).toContain(topics.resolveTopicId(state.doc, "a"));
  });
});

describe("hands-on items", () => {
  const mark = (state: TopicState, input: topics.TodoInput): Extract<TopicResult, { ok: true }> =>
    done(topics.markTodo(state, input, NOW));

  it("records a claim, a rejection with its reason, and that an item is no longer needed", () => {
    let state = mark(topics.emptyState(), { task: "t1", state: "claimed" }).state;
    expect(state.doc.todos).toEqual({ t1: { state: "claimed", at: NOW } });
    const rejected = mark(state, { task: "t1", state: "rejected", reason: "服務沒起來" });
    expect(rejected.line).toBe("ok t1 已標成驗證沒過，回到要使用者動手");
    state = rejected.state;
    expect(state.doc.todos["t1"]).toEqual({ state: "rejected", at: NOW, reason: "服務沒起來" });
    state = mark(state, { task: "t2", state: "obsolete", reason: "改用別的做法" }).state;
    expect(state.doc.todos["t2"]).toEqual({ state: "obsolete", at: NOW, reason: "改用別的做法" });
    expect(state.doc.todos["t1"]?.state).toBe("rejected");
  });

  it("changes nothing when the same mark is repeated, and replaces a different reason", () => {
    const first = mark(topics.emptyState(), { task: "t1", state: "rejected", reason: "a" });
    const again = done(
      topics.markTodo(first.state, { task: "t1", state: "rejected", reason: "a" }, "later"),
    );
    expect(again.changed).toBe(false);
    expect(again.line).toBe("ok t1 本來就已標成驗證沒過，回到要使用者動手");
    expect(again.state.doc.todos["t1"]?.at).toBe(NOW);
    const other = mark(first.state, { task: "t1", state: "rejected", reason: "b" });
    expect(other.changed).toBe(true);
    expect(other.state.doc.todos["t1"]?.reason).toBe("b");
    const claim = mark(topics.emptyState(), { task: "t1", state: "claimed" });
    expect(mark(claim.state, { task: "t1", state: "claimed" }).changed).toBe(false);
  });

  it("refuses a rejection or withdrawal without a one-line reason", () => {
    const state = topics.emptyState();
    for (const reason of [undefined, "", "a\nb", "x".repeat(201)]) {
      const input = {
        task: "t1",
        state: "obsolete" as const,
        ...(reason === undefined ? {} : { reason }),
      };
      expect(refusal(topics.markTodo(state, input, NOW))).toBe("原因要是一行，最多 200 個字。");
    }
    expect(state.doc.todos).toEqual({});
  });

  it("drops the marks of items that are gone, even when its own mark is unchanged", () => {
    let state = mark(topics.emptyState(), { task: "old", state: "claimed" }).state;
    state = mark(state, { task: "keep", state: "claimed" }).state;
    const result = mark(state, { task: "keep", state: "claimed", gone: ["old", "never", "keep"] });
    expect(result.changed).toBe(true);
    expect(result.state.doc.todos).toEqual({ keep: { state: "claimed", at: NOW } });
    expect(state.doc.todos["old"]).toBeDefined();
  });

  it("refuses the one task id it cannot store, and forgets a mark when asked", () => {
    const state = topics.emptyState();
    const refused = topics.markTodo(state, { task: "__proto__", state: "claimed" }, NOW);
    expect(refusal(refused)).toBe("看板不能記這個 task id 的狀態。");
    const marked = mark(state, { task: "t1", state: "claimed" }).state;
    const cleared = done(topics.clearTodo(marked, "t1"));
    expect(cleared.changed).toBe(true);
    expect(cleared.line).toBe("ok t1 回到還沒做");
    expect(cleared.state.doc.todos).toEqual({});
    expect(marked.doc.todos["t1"]).toBeDefined();
    const again = done(topics.clearTodo(cleared.state, "t1"));
    expect(again.changed).toBe(false);
    expect(done(topics.clearTodo(marked, "constructor")).changed).toBe(false);
  });

  it("treats a task named like an object member as an ordinary task", () => {
    const result = mark(topics.emptyState(), { task: "constructor", state: "claimed" });
    expect(result.changed).toBe(true);
    expect(Object.keys(result.state.doc.todos)).toEqual(["constructor"]);
  });
});

describe("why and where a change was made", () => {
  it("keeps the reason given with a merge or a split, and refuses one that is not a line", () => {
    const merged = done(topics.merge(fixture(), "b", "c", NOW, "重複了"));
    expect(merged.state.doc.history.at(-1)).toMatchObject({ kind: "merged", reason: "重複了" });
    const plain = done(topics.merge(fixture(), "b", "c", NOW));
    expect(plain.state.doc.history.at(-1)).not.toHaveProperty("reason");
    const input = { from: "a", name: "A2", goal: "g", id: "a2" };
    const split = done(topics.split(fixture(), { ...input, reason: "太寬" }, NOW));
    expect(split.state.doc.history.at(-1)).toMatchObject({ kind: "split", reason: "太寬" });
    for (const reason of ["", "a\nb", "x".repeat(201)]) {
      expect(refusal(topics.merge(fixture(), "b", "c", NOW, reason))).toBe(
        "原因要是一行，最多 200 個字。",
      );
      expect(refusal(topics.split(fixture(), { ...input, reason }, NOW))).toBe(
        "原因要是一行，最多 200 個字。",
      );
    }
  });

  it("does not record a repeated split again, whatever reason the repeat carries", () => {
    const input = { from: "a", name: "A2", goal: "g", id: "a2" };
    const first = done(topics.split(fixture(), { ...input, reason: "太寬" }, NOW));
    const again = done(topics.split(first.state, { ...input, reason: "另一個說法" }, "later"));
    expect(again.changed).toBe(false);
    expect(again.state.doc.history).toEqual(first.state.doc.history);
  });

  it("carries the close proposal into the archive's entry", () => {
    const proposed = done(topics.closePropose(fixture(), "a", "都做完了", NOW));
    const archived = done(topics.archive(proposed.state, "a", NOW));
    expect(archived.state.doc.history.at(-1)).toEqual({
      at: NOW,
      kind: "archived",
      topic: "a",
      name: "A",
      reason: "都做完了",
    });
    const plain = done(topics.archive(fixture(), "b", NOW));
    expect(plain.state.doc.history.at(-1)).not.toHaveProperty("reason");
  });

  it("stamps only the entries a change added, and leaves the result it was given alone", () => {
    const first = done(topics.rename(fixture(), "a", "A1", NOW));
    const second = topics.rename(first.state, "a", "A2", NOW);
    const stamped = done(topics.stampHistory(second, first.state.doc.history.length, "page"));
    expect(stamped.state.doc.history.map((entry) => entry.by)).toEqual([undefined, "page"]);
    expect(done(second).state.doc.history.at(-1)).not.toHaveProperty("by");
    const unchangedResult = topics.rename(first.state, "a", "A1", NOW);
    expect(topics.stampHistory(unchangedResult, 0, "page")).toBe(unchangedResult);
    const refused = topics.rename(first.state, "nope", "x", NOW);
    expect(topics.stampHistory(refused, 0, "page")).toBe(refused);
    const noHistory = topics.setGoal(first.state, "a", "new goal");
    expect(topics.stampHistory(noHistory, first.state.doc.history.length, "command")).toBe(
      noHistory,
    );
  });
});
