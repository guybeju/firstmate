import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DispatchNotifier } from "./notifier.js";
import { emptyState } from "./topics.js";
import type { Queue, TopicState } from "./topics.js";

function state(queues: Partial<Record<Queue, string[]>>): TopicState {
  const result = emptyState();
  result.doc.queues = { high: [], normal: [], later: [], ...queues };
  return result;
}

describe("DispatchNotifier", () => {
  let notified: string[][];
  let notifier: DispatchNotifier;

  beforeEach(() => {
    vi.useFakeTimers();
    notified = [];
    notifier = new DispatchNotifier(30_000, (ids) => notified.push(ids));
  });
  afterEach(() => {
    notifier.stop();
    vi.useRealTimers();
  });

  it("notifies once the topic has stayed dispatchable for the whole delay", () => {
    notifier.observe(state({ later: ["a"] }), state({ normal: ["a"] }), ["a"]);
    vi.advanceTimersByTime(29_999);
    expect(notified).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(notified).toEqual([["a"]]);
    vi.advanceTimersByTime(120_000);
    expect(notified).toEqual([["a"]]);
  });

  it("cancels when the topic goes back to later, is archived, or disappears", () => {
    for (const after of [state({ later: ["a"] }), state({})]) {
      notifier.observe(state({ later: ["a"] }), state({ normal: ["a"] }), ["a"]);
      vi.advanceTimersByTime(10_000);
      notifier.observe(state({ normal: ["a"] }), after, []);
      vi.advanceTimersByTime(60_000);
    }
    expect(notified).toEqual([]);
  });

  it("restarts the wait when the topic moves again, by queue or by position", () => {
    notifier.observe(state({ later: ["a"] }), state({ normal: ["b", "a"] }), ["a"]);
    vi.advanceTimersByTime(20_000);
    notifier.observe(state({ normal: ["b", "a"] }), state({ normal: ["a", "b"] }), []);
    vi.advanceTimersByTime(20_000);
    notifier.observe(state({ normal: ["a", "b"] }), state({ high: ["a"], normal: ["b"] }), []);
    vi.advanceTimersByTime(29_999);
    expect(notified).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(notified).toEqual([["a"]]);
  });

  it("does not restart the wait for a change that leaves the topic where it is", () => {
    notifier.observe(state({ later: ["a"] }), state({ normal: ["a"] }), ["a"]);
    vi.advanceTimersByTime(20_000);
    notifier.observe(state({ normal: ["a"] }), state({ normal: ["a", "b"] }), []);
    vi.advanceTimersByTime(10_000);
    expect(notified).toEqual([["a"]]);
  });

  it("batches topics due within a second and sends later ones separately", () => {
    notifier.observe(
      state({ later: ["a", "b", "c"] }),
      state({ normal: ["a"], later: ["b", "c"] }),
      ["a"],
    );
    vi.advanceTimersByTime(1000);
    notifier.observe(
      state({ normal: ["a"], later: ["b", "c"] }),
      state({ normal: ["a"], high: ["b"], later: ["c"] }),
      ["b"],
    );
    vi.advanceTimersByTime(1001);
    notifier.observe(
      state({ normal: ["a"], high: ["b"], later: ["c"] }),
      state({ normal: ["a", "c"], high: ["b"] }),
      ["c"],
    );
    vi.advanceTimersByTime(27_999);
    expect(notified).toEqual([["a", "b"]]);
    vi.advanceTimersByTime(2001);
    expect(notified).toEqual([["a", "b"], ["c"]]);
  });

  it("sends nothing after stop", () => {
    notifier.observe(state({ later: ["a"] }), state({ normal: ["a"] }), ["a"]);
    notifier.stop();
    vi.advanceTimersByTime(60_000);
    expect(notified).toEqual([]);
  });
});
