import { describe, expect, it } from "vitest";
import { stampRecord } from "./records.js";

describe("a saved record", () => {
  const actor = { by: "captain" as const, label: "plain" };

  it("carries its id, time and who made it, and only the fields its draft has", () => {
    const bare = stampRecord({ kind: "topic.kept", topic: "a", text: "t" }, actor, "r-1", 5);
    expect(bare).toStrictEqual({
      src: "board",
      rid: "r-1",
      ts: 5,
      kind: "topic.kept",
      topic: "a",
      home: null,
      task: null,
      by: "captain",
      label: "plain",
      text: "t",
    });
    const full = stampRecord(
      {
        kind: "hold.answered",
        topic: null,
        home: "",
        task: "",
        item: "i",
        outcome: "A",
        reason: "r",
        text: "t",
      },
      actor,
      "r-2",
      6,
    );
    expect(full).toMatchObject({ home: "", task: "", item: "i", outcome: "A", reason: "r" });
  });
});
