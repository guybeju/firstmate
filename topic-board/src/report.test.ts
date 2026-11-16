import { describe, expect, it } from "vitest";
import { parseReport } from "./report.js";

const FULL = {
  schema: 1,
  code_commit: "abc",
  ledger_enabled: true,
  tasks: [
    { id: "t1", kind: "ship", state: "working", source: "pane", detail: "busy" },
    { kind: "no id" },
    "junk",
  ],
  holds: [
    {
      id: "h1",
      title: "T",
      question: "Q",
      hold_bucket: "dated",
      hold_until: "2026-12-01",
      unresolved_blocker_ids: ["b", 3],
      hold_age_days: 4,
      origin: "t1",
    },
    { id: "h2", hold_bucket: "weird" },
    { hold_bucket: "live" },
  ],
  status_decisions: [{ id: "t1", key: "default", summary: "which?" }, { key: "no id" }],
  topics: { t1: "billing 2026-07-01T00:00:00Z", bad: 3 },
  ledger: {
    status: "delta",
    to_offset: 10,
    to_prefix_sha256: "s",
    more: true,
    lines: ["a", 1, "b"],
  },
  secondmates: [{ id: "sm1", remote: true, home: "/h" }, { id: "sm2" }, { home: "no id" }],
};

function ok(raw: unknown) {
  const parsed = parseReport(JSON.stringify(raw));
  if (parsed.kind !== "ok") throw new Error(`not ok: ${parsed.kind}`);
  return parsed.report;
}

describe("parseReport", () => {
  it("keeps well-formed entries and drops the rest", () => {
    expect(ok(FULL)).toEqual({
      code_commit: "abc",
      ledger_enabled: true,
      tasks: [{ id: "t1", kind: "ship", state: "working", source: "pane", detail: "busy" }],
      holds: [
        {
          id: "h1",
          title: "T",
          question: "Q",
          hold_bucket: "dated",
          hold_until: "2026-12-01",
          unresolved_blocker_ids: ["b"],
          hold_age_days: 4,
          origin: "t1",
        },
      ],
      status_decisions: [{ id: "t1", key: "default", summary: "which?" }],
      topics: { t1: "billing 2026-07-01T00:00:00Z" },
      ledger: {
        status: "delta",
        to_offset: 10,
        to_prefix_sha256: "s",
        more: true,
        lines: ["a", "b"],
      },
      secondmates: [
        { id: "sm1", remote: true, home: "/h" },
        { id: "sm2", remote: false, home: "" },
      ],
    });
  });

  it("fills defaults for everything optional", () => {
    const report = ok({
      schema: 1,
      tasks: [{ id: "t" }],
      holds: [{ id: "h", hold_bucket: "live" }],
      status_decisions: [{ id: "q" }],
      ledger: { status: "absent", to_offset: 0, to_prefix_sha256: "-" },
    });
    expect(report).toEqual({
      code_commit: "",
      ledger_enabled: false,
      tasks: [{ id: "t", kind: "", state: "unknown", source: "", detail: "" }],
      holds: [
        {
          id: "h",
          title: "",
          question: "",
          hold_bucket: "live",
          hold_until: null,
          unresolved_blocker_ids: [],
          hold_age_days: null,
          origin: "",
        },
      ],
      status_decisions: [{ id: "q", key: "", summary: "" }],
      topics: {},
      ledger: { status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: [] },
      secondmates: [],
    });
  });

  it("accepts each hold bucket and ledger status", () => {
    for (const bucket of ["live", "aged", "dated", "blocked"]) {
      expect(ok({ ...FULL, holds: [{ id: "h", hold_bucket: bucket }] }).holds[0]?.hold_bucket).toBe(
        bucket,
      );
    }
    for (const status of ["delta", "continuity-broken", "absent"]) {
      expect(ok({ ...FULL, ledger: { ...FULL.ledger, status } }).ledger.status).toBe(status);
    }
    expect(ok({ ...FULL, ledger_enabled: "yes" }).ledger_enabled).toBe(false);
    expect(ok({ ...FULL, tasks: [{ id: "t", state: "" }] }).tasks[0]?.state).toBe("");
    expect(ok({ ...FULL, ledger: { ...FULL.ledger, more: 1 } }).ledger.more).toBe(false);
    expect(ok({ ...FULL, secondmates: [{ id: "s", remote: "true" }] }).secondmates[0]?.remote).toBe(
      false,
    );
  });

  it("distinguishes another schema from garbage", () => {
    expect(parseReport(JSON.stringify({ ...FULL, schema: 2 }))).toEqual({ kind: "incompatible" });
    expect(parseReport(JSON.stringify({ ...FULL, schema: "1" }))).toEqual({ kind: "incompatible" });
    expect(parseReport("not json")).toEqual({ kind: "invalid" });
    expect(parseReport("[1]")).toEqual({ kind: "invalid" });
    expect(parseReport("null")).toEqual({ kind: "invalid" });
    for (const ledger of [
      undefined,
      "x",
      { ...FULL.ledger, status: "odd" },
      { ...FULL.ledger, to_offset: "1" },
      { ...FULL.ledger, to_prefix_sha256: 5 },
    ]) {
      expect(parseReport(JSON.stringify({ ...FULL, ledger }))).toEqual({ kind: "invalid" });
    }
  });
});
