// The board's own append-only files: the event journal (every home's ledger
// events plus the board's system records), the milestone summaries, and the
// per-home ledger offsets.
import {
  appendLine,
  isRecord,
  readCompleteLines,
  readJsonFile,
  stringField,
  textField,
  writeFileAtomic,
} from "./files.js";
import type { BoardPaths } from "./layout.js";
import path from "node:path";

const FILE_MODE = 0o644;
export const MAIN_HOME = "main";

export interface LedgerEvent {
  src: "ledger";
  home: string;
  /** Seconds since the epoch, as the ledger recorded it. */
  ts: number;
  event: string;
  task: string;
  fields: Record<string, unknown>;
}

export interface BoardEvent {
  src: "board";
  ts: number;
  kind: string;
  topic: string | null;
  home: string | null;
  task: string | null;
  text: string;
}

export type JournalEvent = LedgerEvent | BoardEvent;

function parseLedgerLine(home: string, raw: string): LedgerEvent | null {
  let line: unknown;
  try {
    line = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(line)) return null;
  const event = stringField(line, "event");
  const task = stringField(line, "task");
  const ts = line["ts"];
  if (event === null || task === null || typeof ts !== "number") return null;
  return { src: "ledger", home, ts, event, task, fields: line };
}

function parseStoredLedger(stored: Record<string, unknown>): {
  event: JournalEvent | null;
  key: string | null;
} {
  const home = stringField(stored, "home");
  const raw = stringField(stored, "raw");
  if (home === null || raw === null) return { event: null, key: null };
  return { event: parseLedgerLine(home, raw), key: `${home}\n${raw}` };
}

function parseStoredBoard(stored: Record<string, unknown>): BoardEvent | null {
  const ts = stored["ts"];
  const kind = stringField(stored, "kind");
  if (typeof ts !== "number" || kind === null) return null;
  return {
    src: "board",
    ts,
    kind,
    topic: stringField(stored, "topic"),
    home: stringField(stored, "home"),
    task: stringField(stored, "task"),
    text: textField(stored, "text"),
  };
}

function parseStored(text: string): { event: JournalEvent | null; key: string | null } {
  let stored: unknown;
  try {
    stored = JSON.parse(text);
  } catch {
    return { event: null, key: null };
  }
  if (!isRecord(stored)) return { event: null, key: null };
  if (stored["src"] === "ledger") return parseStoredLedger(stored);
  return { event: stored["src"] === "board" ? parseStoredBoard(stored) : null, key: null };
}

/** Every event the board knows, in the order it learned them. */
export class Journal {
  readonly events: JournalEvent[] = [];
  private readonly seen = new Set<string>();

  constructor(private readonly file: string) {
    for (const line of readCompleteLines(file)) {
      const { event, key } = parseStored(line);
      if (key !== null) this.seen.add(key);
      if (event !== null) this.events.push(event);
    }
  }

  /** Stores the ledger lines not seen before for `home`; returns how many were new. */
  appendLedger(home: string, rawLines: string[]): number {
    let added = 0;
    for (const raw of rawLines) {
      const key = `${home}\n${raw}`;
      if (this.seen.has(key)) continue;
      this.seen.add(key);
      appendLine(this.file, JSON.stringify({ src: "ledger", home, raw }), FILE_MODE);
      const event = parseLedgerLine(home, raw);
      if (event !== null) this.events.push(event);
      added += 1;
    }
    return added;
  }

  appendBoard(event: Omit<BoardEvent, "src">): void {
    const stored: BoardEvent = { src: "board", ...event };
    appendLine(this.file, JSON.stringify(stored), FILE_MODE);
    this.events.push(stored);
  }
}

export const SUMMARY_KINDS = ["ready", "report", "failed", "landed"] as const;
export type SummaryKind = (typeof SUMMARY_KINDS)[number];
export const SUMMARY_MAX = 600;

export interface Summary {
  ts: number;
  home: string;
  task: string;
  kind: SummaryKind;
  text: string;
}

function parseSummary(text: string): Summary | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isRecord(raw)) return null;
  const kind = SUMMARY_KINDS.find((name) => name === raw["kind"]);
  const home = stringField(raw, "home");
  const task = stringField(raw, "task");
  const body = stringField(raw, "text");
  const ts = raw["ts"];
  if (
    kind === undefined ||
    home === null ||
    task === null ||
    body === null ||
    typeof ts !== "number"
  )
    return null;
  return { ts, home, task, kind, text: body };
}

export class Summaries {
  readonly all: Summary[] = [];

  constructor(private readonly file: string) {
    for (const line of readCompleteLines(file)) {
      const summary = parseSummary(line);
      if (summary !== null) this.all.push(summary);
    }
  }

  /** Stores `summary` unless an identical one exists; returns whether it was new. */
  add(summary: Summary): boolean {
    const duplicate = this.all.some(
      (known) =>
        known.home === summary.home &&
        known.task === summary.task &&
        known.kind === summary.kind &&
        known.text === summary.text,
    );
    if (duplicate) return false;
    appendLine(this.file, JSON.stringify(summary), FILE_MODE);
    this.all.push(summary);
    return true;
  }
}

export interface LedgerCursor {
  offset: number;
  sha: string;
}

/** Where the board stopped reading each home's ledger. */
export class Offsets {
  private readonly cursors = new Map<string, LedgerCursor>();
  private readonly file: string;

  constructor(paths: BoardPaths) {
    this.file = path.join(paths.boardDataDir, "offsets.json");
    let raw: unknown = null;
    try {
      raw = readJsonFile(this.file);
    } catch {
      raw = null;
    }
    if (!isRecord(raw)) return;
    for (const [home, cursor] of Object.entries(raw)) {
      if (!isRecord(cursor)) continue;
      const sha = stringField(cursor, "sha");
      if (typeof cursor["offset"] === "number" && sha !== null) {
        this.cursors.set(home, { offset: cursor["offset"], sha });
      }
    }
  }

  get(home: string): LedgerCursor {
    const cursor = this.cursors.get(home);
    return cursor === undefined ? { offset: 0, sha: "-" } : cursor;
  }

  /** Remembers the cursor; the file is rewritten only when the cursor moved. */
  set(home: string, cursor: LedgerCursor): void {
    const current = this.get(home);
    if (current.offset === cursor.offset && current.sha === cursor.sha) return;
    this.cursors.set(home, cursor);
    writeFileAtomic(
      this.file,
      `${JSON.stringify(Object.fromEntries(this.cursors), null, 2)}\n`,
      FILE_MODE,
    );
  }
}
