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
    const renamed = done(topics.rename(state, "a", "  New  "));
    expect(renamed.state.doc.topics["a"]?.name).toBe("New");
    expect(renamed.line).toBe("ok a 名稱已改");
    expect(done(topics.rename(renamed.state, "a", "New")).changed).toBe(false);
    const goal = done(topics.setGoal(state, "p", "fresh goal"));
    expect(goal.state.doc.topics["p"]?.goal).toBe("fresh goal");
    expect(goal.line).toBe("ok p 目標已改");
    expect(refusal(topics.rename(state, "a", ""))).toContain("名稱");
    expect(refusal(topics.rename(state, "a", "x".repeat(topics.NAME_MAX + 1)))).toContain("名稱");
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

    const reopened = done(topics.reopen(archived.state, "b", undefined));
    expect(reopened.state.archive.topics["b"]).toBeUndefined();
    expect(reopened.state.doc.queues.normal).toEqual(["c", "b"]);
    expect(reopened.state.doc.topics["b"]).not.toHaveProperty("archived_at");
    expect(reopened.dispatchable).toEqual(["b"]);
    expect(reopened.line).toBe("ok b 已重開，放進「一般」");
    expect(done(topics.reopen(archived.state, "b", "later")).dispatchable).toEqual([]);
    expect(done(topics.reopen(archived.state, "b", "high")).state.doc.queues.high).toEqual([
      "a",
      "b",
    ]);
    expect(done(topics.reopen(reopened.state, "b", undefined)).changed).toBe(false);
  });

  it("turns down a proposal by archiving it and accepts it on reopen", () => {
    const state = fixture();
    const dismissed = done(topics.archive(state, "p", NOW));
    expect(dismissed.state.archive.topics["p"]?.status).toBe("proposed");
    const accepted = done(topics.reopen(dismissed.state, "p", "high"));
    expect(accepted.state.doc.topics["p"]?.status).toBe("confirmed");
    expect(refusal(topics.archive(state, "nope", NOW))).toContain("沒有 nope");
    expect(refusal(topics.reopen(state, "nope", undefined))).toContain("沒有 nope");
  });
});

describe("merge", () => {
  it("aliases the old id and removes the old topic", () => {
    const state = fixture();
    const merged = done(topics.merge(state, "b", "a"));
    expect(merged.state.doc.merged).toEqual({ b: "a" });
    expect(merged.state.doc.topics["b"]).toBeUndefined();
    expect(merged.state.doc.queues.normal).toEqual(["c"]);
    expect(merged.events[0]).toEqual({
      kind: "topic.merged",
      topic: "a",
      text: "議題「B」已併入「A」",
    });
    expect(topics.resolveTopicId(merged.state.doc, "b")).toBe("a");
    expect(done(topics.merge(merged.state, "b", "a")).changed).toBe(false);
    expect(done(topics.rename(merged.state, "b", "Via alias")).state.doc.topics["a"]?.name).toBe(
      "Via alias",
    );
  });

  it("follows chains and merges a proposal", () => {
    const first = done(topics.merge(fixture(), "b", "a")).state;
    const second = done(topics.merge(first, "a", "c")).state;
    expect(topics.resolveTopicId(second.doc, "b")).toBe("c");
    expect(done(topics.merge(second, "p", "b")).state.doc.merged["p"]).toBe("c");
  });

  it("refuses merging into itself, a proposal, an archived or an unknown topic", () => {
    const state = fixture();
    expect(refusal(topics.merge(state, "a", "a"))).toContain("它自己");
    expect(refusal(topics.merge(state, "a", "p"))).toContain("提議中");
    expect(refusal(topics.merge(state, "nope", "a"))).toContain("沒有 nope");
    expect(refusal(topics.merge(state, "a", "nope"))).toContain("沒有 nope");
    const archived = done(topics.archive(state, "b", NOW)).state;
    expect(refusal(topics.merge(archived, "a", "b"))).toContain("已封存");
    expect(refusal(topics.merge(archived, "b", "a"))).toContain("已封存");
    expect(
      refusal(
        topics.propose(
          done(topics.merge(state, "b", "a")).state,
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
