import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { boardPaths } from "./layout.js";
import { loadTodos, saveTodos } from "./store.js";
import * as todos from "./todos.js";
import type { TodoInput, TodoResult, TodoStore } from "./todos.js";
import { emptyState } from "./topics.js";
import type { TopicState } from "./topics.js";

const NOW = "2026-11-20T00:00:00Z";
const LATER = "2026-11-20T01:00:00Z";

function board(): TopicState {
  const state = emptyState();
  const topic = (name: string) => ({
    name,
    goal: "g",
    status: "confirmed" as const,
    created_at: "",
  });
  state.doc.topics = { solo: topic("建置"), wrap: topic("收尾") };
  state.doc.queues = { high: ["solo"], normal: ["wrap"], later: [] };
  state.doc.merged = { old: "solo" };
  state.archive.topics = { gone: { ...topic("Gone"), archived_at: "" } };
  return state;
}

function input(extra: Partial<TodoInput> = {}): TodoInput {
  return {
    id: "vpn-login",
    title: "登入 VPN",
    topic: "solo",
    action: "用公司帳號登入 VPN",
    guidance: "",
    commands: [],
    ref: "",
    captainCloses: false,
    adopt: false,
    ...extra,
  };
}

function ok(result: TodoResult): Extract<TodoResult, { ok: true }> {
  if (!result.ok) throw new Error(`expected success, got: ${result.line}`);
  return result;
}

function refusal(result: TodoResult): string {
  if (result.ok) throw new Error(`expected a refusal, got: ${result.line}`);
  return result.line;
}

function added(extra: Partial<TodoInput> = {}, store: TodoStore = todos.emptyTodos()): TodoStore {
  return ok(todos.addItem(store, board(), input(extra), NOW, "plain")).store;
}

describe("adding an item", () => {
  it("stores an action, guidance and each command exactly, open, under a live topic", () => {
    const commands = ["sudo tee /etc/x <<'EOF'\n\tkey = 1\nEOF", "說明：只是指令"];
    const result = ok(
      todos.addItem(
        todos.emptyTodos(),
        board(),
        input({ guidance: "先關 VPN。", commands, ref: "r1" }),
        NOW,
        "plain",
      ),
    );
    expect(result.line).toBe("ok vpn-login 已放上看板的「要你動手」（議題 solo）");
    expect(result.store.items["vpn-login"]).toEqual({
      title: "登入 VPN",
      topic: "solo",
      action: "用公司帳號登入 VPN",
      guidance: "先關 VPN。",
      commands,
      state: "open",
      reason: null,
      at: NOW,
      by: "plain",
      ref: "r1",
      captain_closes: false,
      created_at: NOW,
    });
    expect(result.events).toEqual([]);
    expect(result.notices).toEqual([]);
  });

  it("follows a merged topic, and refuses an archived or unknown topic or none", () => {
    expect(added({ topic: "old" }).items["vpn-login"]?.topic).toBe("solo");
    expect(
      refusal(todos.addItem(todos.emptyTodos(), board(), input({ topic: "nope" }), NOW, "p")),
    ).toBe("nope 不是看板上還開著的議題，沒有放上任何東西。");
    expect(todos.addItem(todos.emptyTodos(), board(), input({ topic: "gone" }), NOW, "p").ok).toBe(
      false,
    );
    expect(
      todos.addItem(todos.emptyTodos(), board(), input({ topic: null }), NOW, "p"),
    ).toMatchObject({ ok: false, code: "usage" });
  });

  it("changes nothing when repeated, and starts a rewritten item over", () => {
    const first = added();
    const claimed = ok(todos.claimItem(first, "vpn-login", NOW, "plain")).store;
    const again = ok(todos.addItem(claimed, board(), input(), LATER, "plain"));
    expect(again.changed).toBe(false);
    const rewritten = ok(
      todos.addItem(claimed, board(), input({ action: "改用新的帳號" }), LATER, "plain"),
    );
    expect(rewritten.changed).toBe(true);
    expect(rewritten.store.items["vpn-login"]).toMatchObject({
      state: "open",
      reason: null,
      created_at: NOW,
      at: LATER,
    });
  });

  it("refuses malformed parts as usage", () => {
    const bad: Partial<TodoInput>[] = [
      { id: "bad id" },
      { id: "__proto__" },
      { title: "" },
      { action: "a\nb" },
      { commands: [" "] },
      { ref: "x".repeat(129) },
    ];
    for (const extra of bad)
      expect(todos.addItem(todos.emptyTodos(), board(), input(extra), NOW, "p")).toMatchObject({
        ok: false,
        code: "usage",
      });
  });
});

describe("adopting an item from before the board kept items", () => {
  it("keeps where today's page shows it: archived kept, unknown or no topic is none", () => {
    expect(added({ adopt: true, topic: "gone" }).items["vpn-login"]?.topic).toBe("gone");
    expect(added({ adopt: true, topic: "nope" }).items["vpn-login"]?.topic).toBeNull();
    const none = ok(
      todos.addItem(todos.emptyTodos(), board(), input({ adopt: true, topic: null }), NOW, "p"),
    );
    expect(none.store.items["vpn-login"]?.topic).toBeNull();
    expect(none.line).toBe("ok vpn-login 已放上看板的「要你動手」（沒有議題）");
  });

  it("takes its waiting mark as its state, and changes nothing once on the board", () => {
    const store = {
      ...todos.emptyTodos(),
      marks: { "vpn-login": { state: "obsolete" as const, at: "T", reason: "不用了" } },
    };
    const adopted = added({ adopt: true, ref: "hold", captainCloses: true }, store);
    expect(adopted.items["vpn-login"]).toMatchObject({
      state: "obsolete",
      reason: "不用了",
      at: "T",
      ref: "hold",
      captain_closes: true,
    });
    expect(adopted.marks).toEqual({});
    const again = ok(
      todos.addItem(adopted, board(), input({ adopt: true, action: "別的字" }), LATER, "p"),
    );
    expect(again.changed).toBe(false);
  });
});

describe("the life of an item", () => {
  it("claims once, with today's words, and refuses a claim on an item no longer needed", () => {
    const store = added();
    const claim = ok(todos.claimItem(store, "vpn-login", NOW, "plain"));
    expect(claim.notices).toEqual([
      {
        event: "todo.claimed",
        id: "vpn-login",
        title: "登入 VPN",
        ref: "",
        topic: "solo",
        text: "使用者在看板上：「登入 VPN」做完了（vpn-login）。驗證後跑 bin/myshape.sh todo done vpn-login；沒成功就跑 bin/myshape.sh todo failed vpn-login --reason <一行>",
      },
    ]);
    const again = ok(todos.claimItem(claim.store, "vpn-login", LATER, "plain"));
    expect(again.changed).toBe(false);
    expect(again.notices).toEqual([]);
    const held = added({ captainCloses: true });
    const obsolete = ok(todos.obsoleteItem(held, "vpn-login", "不用了", NOW, "plain")).store;
    expect(refusal(todos.claimItem(obsolete, "vpn-login", NOW, "plain"))).toBe(
      "vpn-login 已經被 plain 標成不再需要，請直接撤下。",
    );
    expect(refusal(todos.claimItem(store, "nope", NOW, "plain"))).toContain(
      "不是看板上還開著的「要你動手」項目",
    );
  });

  it("puts a failed check back in front of the captain with its reason", () => {
    const claimed = ok(todos.claimItem(added(), "vpn-login", NOW, "p")).store;
    const failed = ok(todos.rejectItem(claimed, "vpn-login", "服務沒起來", LATER));
    expect(failed.line).toBe("ok vpn-login 已標成驗證沒過，回到要使用者動手");
    expect(failed.store.items["vpn-login"]).toMatchObject({
      state: "rejected",
      reason: "服務沒起來",
      at: LATER,
    });
    expect(ok(todos.rejectItem(failed.store, "vpn-login", "服務沒起來", LATER)).changed).toBe(
      false,
    );
    for (const reason of ["", "a\nb", "x".repeat(201)])
      expect(refusal(todos.rejectItem(claimed, "vpn-login", reason, LATER))).toBe(
        "原因要是一行，最多 200 個字。",
      );
  });

  it("closes on done, with a record on its topic and a notice by the aggregator", () => {
    const done = ok(todos.doneItem(added(), "vpn-login", "plain"));
    expect(done.line).toBe("ok vpn-login 已關（做完了，plain 已驗證）");
    expect(done.store.items).toEqual({});
    expect(done.events).toEqual([
      {
        kind: "todo.done",
        topic: "solo",
        task: "vpn-login",
        text: "「登入 VPN」做完了，plain 已驗證（plain 用指令）",
      },
    ]);
    expect(done.notices).toMatchObject([
      { event: "todo.closed", by: "aggregator", words: "做完了", id: "vpn-login" },
    ]);
    expect(refusal(todos.doneItem(done.store, "vpn-login", "plain"))).toBe(
      "vpn-login 不是開著的「要你動手」項目，沒有關任何東西（已經關過的話不用再跑）。",
    );
  });

  it("takes an item no longer needed down at once, unless only the captain may close it", () => {
    const down = ok(todos.obsoleteItem(added(), "vpn-login", "改用別的做法", NOW, "plain"));
    expect(down.store.items).toEqual({});
    expect(down.events).toEqual([
      {
        kind: "todo.taken_down",
        topic: "solo",
        task: "vpn-login",
        text: "「登入 VPN」不再需要，plain 撤下：改用別的做法（plain 用指令）",
      },
    ]);
    expect(down.notices).toMatchObject([{ event: "todo.closed", by: "aggregator", words: "撤下" }]);
    const held = ok(
      todos.obsoleteItem(added({ captainCloses: true }), "vpn-login", "改用別的做法", NOW, "plain"),
    );
    expect(held.line).toBe("ok vpn-login 已標成不再需要，等使用者撤下");
    expect(held.store.items["vpn-login"]).toMatchObject({
      state: "obsolete",
      reason: "改用別的做法",
    });
    expect(held.events).toEqual([]);
    expect(held.notices).toEqual([]);
  });

  it("closes on the captain's 不做了 and 好，撤下, with the captain's words", () => {
    const dropped = ok(todos.closeByCaptain(added(), "vpn-login", "不做了", "plain"));
    expect(dropped.events).toEqual([
      {
        kind: "todo.dropped",
        topic: "solo",
        task: "vpn-login",
        text: "「登入 VPN」使用者按了不做了（在頁面上）",
      },
    ]);
    expect(dropped.notices).toMatchObject([
      {
        event: "todo.closed",
        by: "captain",
        words: "不做了",
        text: "使用者在看板上：「登入 VPN」不做了（vpn-login）",
      },
    ]);
    expect(refusal(todos.closeByCaptain(added(), "vpn-login", "撤下", "plain"))).toBe(
      "vpn-login 沒有被標成不再需要，不能撤下。",
    );
    const held = ok(
      todos.obsoleteItem(
        added({ captainCloses: true, ref: "hold" }),
        "vpn-login",
        "不用了",
        NOW,
        "plain",
      ),
    ).store;
    expect(refusal(todos.closeByCaptain(held, "vpn-login", "不做了", "plain"))).toBe(
      "vpn-login 現在不能按不做了。",
    );
    const takenDown = ok(todos.closeByCaptain(held, "vpn-login", "撤下", "plain"));
    expect(takenDown.events[0]).toMatchObject({
      kind: "todo.taken_down",
      text: "「登入 VPN」不再需要（plain：不用了），使用者按了好，撤下（在頁面上）",
    });
    expect(takenDown.notices).toMatchObject([{ by: "captain", words: "撤下", ref: "hold" }]);
    const claimed = ok(todos.claimItem(added(), "vpn-login", NOW, "p")).store;
    expect(todos.closeByCaptain(claimed, "vpn-login", "不做了", "plain").ok).toBe(false);
  });

  it("gives an item with no topic its closing record too", () => {
    const none = added({ adopt: true, topic: null });
    expect(ok(todos.doneItem(none, "vpn-login", "p")).events[0]).toMatchObject({
      kind: "todo.done",
      topic: null,
    });
  });
});

describe("ending an adoption pass", () => {
  it("drops waiting marks of holds that are gone and retires adopted items whose hold is gone", () => {
    let store: TodoStore = {
      ...todos.emptyTodos(),
      marks: { kept: { state: "claimed", at: "T" }, lost: { state: "claimed", at: "T" } },
    };
    store = added({ id: "adopted", ref: "hold", adopt: true }, store);
    store = added({ id: "still", ref: "hold", adopt: true }, store);
    store = added({ id: "fresh" }, store);
    const result = ok(todos.adoptDone(store, ["kept", "still"], "first mate"));
    expect(Object.keys(result.store.marks)).toEqual(["kept"]);
    expect(Object.keys(result.store.items).toSorted()).toEqual(["fresh", "still"]);
    expect(result.events).toEqual([
      {
        kind: "todo.closed_elsewhere",
        topic: "solo",
        task: "adopted",
        text: "「登入 VPN」的 hold 已在別處關掉，從看板拿掉（first mate 用指令）",
      },
    ]);
    expect(result.notices).toEqual([]);
    expect(ok(todos.adoptDone(result.store, ["kept", "still"], "first mate")).changed).toBe(false);
  });
});

describe("what topics.json keeps publishing", () => {
  it("is the mark of every item that is not open, plus every waiting mark", () => {
    let store: TodoStore = {
      ...todos.emptyTodos(),
      marks: { waiting: { state: "claimed", at: "T" } },
    };
    store = added({ id: "open" }, store);
    store = added({ id: "rejected" }, store);
    store = ok(todos.rejectItem(store, "rejected", "沒起來", LATER)).store;
    expect(todos.projectMarks(store)).toEqual({
      waiting: { state: "claimed", at: "T" },
      rejected: { state: "rejected", at: LATER, reason: "沒起來" },
    });
  });
});

describe("the file", () => {
  let dir = "";
  afterEach(() => {
    if (dir !== "") fs.rmSync(dir, { recursive: true, force: true });
  });

  it("is created at the first start with topics.json's marks, and read back as written", () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-todos-"));
    const paths = boardPaths({ state: path.join(dir, "state"), data: path.join(dir, "data") });
    const doc = emptyState().doc;
    doc.todos = { old: { state: "rejected", at: "T", reason: "沒起來" } };
    const first = loadTodos(paths, doc);
    expect(first).toEqual({ v: 1, items: {}, marks: doc.todos });
    expect(fs.statSync(paths.todos).mode & 0o777).toBe(0o644);
    const store = added({ adopt: true, ref: "hold" }, first);
    saveTodos(paths, store);
    expect(loadTodos(paths, emptyState().doc)).toEqual(store);
  });

  it("skips an item it cannot read and refuses a file that is not v1", () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-todos-"));
    const paths = boardPaths({ state: path.join(dir, "state"), data: path.join(dir, "data") });
    fs.mkdirSync(paths.boardDataDir, { recursive: true });
    const good = added().items["vpn-login"];
    fs.writeFileSync(
      paths.todos,
      JSON.stringify({ v: 1, items: { ok: good, bad: { title: 1 }, "bad id": good }, marks: {} }),
    );
    expect(Object.keys(loadTodos(paths, emptyState().doc).items)).toEqual(["ok"]);
    fs.writeFileSync(paths.todos, JSON.stringify({ v: 2 }));
    expect(() => loadTodos(paths, emptyState().doc)).toThrow("讀不懂");
  });
});
