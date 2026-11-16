// The JSON one home's fm-topic-board-read.sh prints, parsed and checked once
// where it enters the service.
import { isRecord, stringField, stringRecord, textField } from "./files.js";
import type { Secondmate } from "./commands.js";

export const REPORT_SCHEMA = 1;

export interface ReportTask {
  id: string;
  kind: string;
  state: string;
  source: string;
  detail: string;
  /** True when the home says the harness is still on the busy record seeded at spawn. */
  unstarted: boolean;
}

export interface ReportHold {
  id: string;
  title: string;
  question: string;
  hold_bucket: "live" | "aged" | "dated" | "blocked";
  hold_until: string | null;
  unresolved_blocker_ids: string[];
  hold_age_days: number | null;
  origin: string;
}

export interface ReportQuestion {
  id: string;
  key: string;
  summary: string;
}

export interface ReportLedger {
  status: "delta" | "continuity-broken" | "absent";
  to_offset: number;
  to_prefix_sha256: string;
  more: boolean;
  lines: string[];
}

export interface HomeReport {
  code_commit: string;
  ledger_enabled: boolean;
  tasks: ReportTask[];
  holds: ReportHold[];
  status_decisions: ReportQuestion[];
  /** Task id to the raw text of its tag file. */
  topics: Record<string, string>;
  ledger: ReportLedger;
  secondmates: Secondmate[];
}

export type ParsedReport =
  | { kind: "ok"; report: HomeReport }
  | { kind: "incompatible" }
  | { kind: "invalid" };

function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.filter(isRecord) : [];
}

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === "string")
    : [];
}

const BUCKETS = ["live", "aged", "dated", "blocked"] as const;

function parseHold(raw: Record<string, unknown>): ReportHold | null {
  const id = stringField(raw, "id");
  const bucket = BUCKETS.find((name) => name === raw["hold_bucket"]);
  if (id === null || bucket === undefined) return null;
  const age = raw["hold_age_days"];
  return {
    id,
    title: textField(raw, "title"),
    question: textField(raw, "question"),
    hold_bucket: bucket,
    hold_until: stringField(raw, "hold_until"),
    unresolved_blocker_ids: strings(raw["unresolved_blocker_ids"]),
    hold_age_days: typeof age === "number" ? age : null,
    origin: textField(raw, "origin"),
  };
}

function parseLedger(raw: unknown): ReportLedger | null {
  if (!isRecord(raw)) return null;
  const status = raw["status"];
  const offset = raw["to_offset"];
  const sha = stringField(raw, "to_prefix_sha256");
  if (status !== "delta" && status !== "continuity-broken" && status !== "absent") return null;
  if (typeof offset !== "number" || sha === null) return null;
  return {
    status,
    to_offset: offset,
    to_prefix_sha256: sha,
    more: raw["more"] === true,
    lines: strings(raw["lines"]),
  };
}

/** Builds an entry from a record that must carry a string `id`. */
function withId<T>(raw: Record<string, unknown>, build: (id: string) => T): T | null {
  const id = stringField(raw, "id");
  return id === null ? null : build(id);
}

/** A task's crew state; a report that omits it means the state is not known. */
function stateOf(raw: Record<string, unknown>): string {
  const state = stringField(raw, "state");
  return state === null ? "unknown" : state;
}

function parseTask(raw: Record<string, unknown>): ReportTask | null {
  return withId(raw, (id) => ({
    id,
    kind: textField(raw, "kind"),
    state: stateOf(raw),
    source: textField(raw, "source"),
    detail: textField(raw, "detail"),
    unstarted: raw["unstarted"] === true,
  }));
}

function parseSecondmate(raw: Record<string, unknown>): Secondmate | null {
  return withId(raw, (id) => ({
    id,
    remote: raw["remote"] === true,
    home: textField(raw, "home"),
  }));
}

function parseQuestion(raw: Record<string, unknown>): ReportQuestion | null {
  return withId(raw, (id) => ({
    id,
    key: textField(raw, "key"),
    summary: textField(raw, "summary"),
  }));
}

function present<T>(value: T | null): value is T {
  return value !== null;
}

export function parseReport(stdout: string): ParsedReport {
  let raw: unknown;
  try {
    raw = JSON.parse(stdout);
  } catch {
    return { kind: "invalid" };
  }
  if (!isRecord(raw)) return { kind: "invalid" };
  if (raw["schema"] !== REPORT_SCHEMA) return { kind: "incompatible" };
  const ledger = parseLedger(raw["ledger"]);
  if (ledger === null) return { kind: "invalid" };
  return {
    kind: "ok",
    report: {
      code_commit: textField(raw, "code_commit"),
      ledger_enabled: raw["ledger_enabled"] === true,
      tasks: records(raw["tasks"]).map(parseTask).filter(present),
      holds: records(raw["holds"]).map(parseHold).filter(present),
      status_decisions: records(raw["status_decisions"]).map(parseQuestion).filter(present),
      topics: stringRecord(raw["topics"]),
      ledger,
      secondmates: records(raw["secondmates"]).map(parseSecondmate).filter(present),
    },
  };
}
