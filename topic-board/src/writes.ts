// Everything the board sends out on the captain's behalf: notes to firstmate,
// direct messages to agents, answers to captain holds, and topic tags. Each
// write is recorded in the audit log before it runs and at every state change,
// retried only when a retry cannot take effect twice, and resumed after a
// restart from the audit log alone.
import crypto from "node:crypto";
import type { CommandResult, CommandRunner, Placement, Secondmate, WriteCommand } from "./commands.js";
import { appendLine, isRecord, readCompleteLines, stringField } from "./files.js";
import { MAIN_HOME } from "./journal.js";

export type WriteState =
  | "sending"
  | "retrying"
  | "delivered"
  | "handled_elsewhere"
  | "failed"
  | "undelivered"
  | "unknown"
  | "ignored";

/** What a write does, with everything needed to run it again after a restart. */
export type WritePlan =
  | { type: "note"; requestId: string; body: string }
  | { type: "send"; task: string }
  | { type: "relay"; secondmate: string; remote: boolean; deliveryId: string }
  | { type: "answer"; placement: Placement; line: string; noteBody: string; answered: boolean }
  | { type: "tag"; placement: Placement; task: string; topic: string; lastLineAtSend: string };

export interface WriteRecord {
  id: string;
  channel: "browser" | "socket" | "auto";
  /** The home the write targets: "main" or a secondmate id. */
  home: string;
  task: string | null;
  topic: string | null;
  /** The captain's own words, shown next to the write's status. */
  text: string;
  plan: WritePlan;
  state: WriteState;
  attempt: number;
  error: string | null;
  nextAt: number | null;
  createdAt: number;
}

export interface WriteTimings {
  retryDelaysMs: number[];
  /** A dedupable write left unfinished by a restart is resumed only this long after it was created. */
  resumeWindowMs: number;
  commandTimeoutMs: number;
}

export const DEFAULT_WRITE_TIMINGS: WriteTimings = {
  retryDelaysMs: [10_000, 30_000, 60_000, 300_000, 900_000],
  resumeWindowMs: 30 * 60_000,
  commandTimeoutMs: 400_000,
};

type Outcome =
  | { kind: "delivered" }
  | { kind: "handled_elsewhere" }
  | { kind: "failed"; error: string }
  | { kind: "retry"; error: string };

/** What the engine needs from the rest of the service. */
export interface WriteHost {
  run: CommandRunner;
  secondmates: () => Secondmate[];
  /** Reads `home` afresh and returns the task's tag file text, or null when the read failed. */
  readTags: (home: string, task: string) => Promise<string | null>;
  /** Resolves once the list of secondmates is known. */
  prepare: () => Promise<void>;
  /** Called when a write changes what the board shows. */
  onChange: () => void;
  /** Called once when a write is delivered, so the service can record it and refresh. */
  onDelivered: (record: WriteRecord) => void;
}

const AUDIT_MODE = 0o600;
const UNFINISHED: WriteState[] = ["sending", "retrying"];
export const NEEDS_ATTENTION: WriteState[] = ["failed", "undelivered", "unknown"];

function errorText(result: CommandResult): string {
  return (result.stderr.trim() || result.stdout.trim() || `exit ${result.code ?? "?"}`).slice(0, 600);
}

function lastLine(text: string): string {
  return text.trimEnd().split("\n").pop() ?? "";
}

/** True when repeating the write after an unknown outcome cannot make it take effect twice. */
export function isDedupable(plan: WritePlan): boolean {
  switch (plan.type) {
    case "note":
      return true;
    case "send":
      return false;
    case "relay":
      return plan.remote;
    case "answer":
    case "tag":
      return true;
  }
}

function secondmateOf(record: WriteRecord): { secondmate?: string } {
  return record.home === MAIN_HOME ? {} : { secondmate: record.home };
}

function noteOutcome(result: CommandResult): Outcome {
  if (result.code === 0) return { kind: "delivered" };
  // Exit 3: the note is saved but firstmate was not woken; replaying the same request id wakes it.
  return result.code === 3 ? { kind: "retry", error: errorText(result) } : { kind: "failed", error: errorText(result) };
}

/** Reads fm-captain-hold.sh answers output for the line about `task`. */
function answerOutcome(result: CommandResult, task: string, remote: boolean): Outcome | "closed" {
  const lines = result.stdout.split("\n").map((line) => line.trim());
  if (lines.includes(`closed: ${task}`)) return "closed";
  const verdict = lines.find((line) => line.startsWith(`skipped: ${task} `) || line.startsWith(`refused: ${task} `));
  if (verdict === `skipped: ${task} (already closed)`) return { kind: "handled_elsewhere" };
  if (verdict !== undefined) return { kind: "failed", error: verdict };
  if (remote && result.code === 255) return { kind: "retry", error: errorText(result) };
  return { kind: "failed", error: errorText(result) };
}

/** One audit line about a write; lines about rejected requests carry no write id and yield null. */
function parseAuditLine(line: string): { id: string; state: WriteState; fields: Record<string, unknown> } | null {
  let entry: unknown;
  try {
    entry = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(entry)) return null;
  const id = stringField(entry, "write_id");
  const state = stringField(entry, "state") as WriteState | null;
  return id === null || state === null ? null : { id, state, fields: entry };
}

export class WriteEngine {
  readonly records = new Map<string, WriteRecord>();
  private readonly queues = new Map<string, Promise<void>>();
  private readonly timers = new Set<NodeJS.Timeout>();

  constructor(
    private readonly auditFile: string,
    private readonly host: WriteHost,
    private readonly timings: WriteTimings,
  ) {
    for (const line of readCompleteLines(this.auditFile)) this.replay(line);
  }

  /**
   * Finishes or settles the writes a restart interrupted. Called once the
   * service is fully built; the main home is read first because relays and
   * remote writes are only allowed to secondmates it lists.
   */
  async resumeUnfinished(): Promise<void> {
    const unfinished = [...this.records.values()].filter((record) => UNFINISHED.includes(record.state));
    if (unfinished.length === 0) return;
    await this.host.prepare();
    for (const record of unfinished) this.resume(record);
  }

  /** Records a new write as "sending" and starts delivering it. */
  submit(input: Pick<WriteRecord, "channel" | "home" | "task" | "topic" | "text" | "plan">): WriteRecord {
    const record: WriteRecord = {
      ...input,
      id: `w-${Date.now().toString(36)}-${crypto.randomBytes(3).toString("hex")}`,
      state: "sending",
      attempt: 0,
      error: null,
      nextAt: null,
      createdAt: Date.now(),
    };
    this.records.set(record.id, record);
    this.audit(record, { sending: record });
    this.enqueue(record, false);
    return record;
  }

  /** Sends a failed write again under the same id and dedupe key. */
  resend(id: string, confirmed: boolean): string | null {
    const record = this.records.get(id);
    if (record === undefined) return "沒有這筆寫入。";
    if (!NEEDS_ATTENTION.includes(record.state)) return "這筆寫入不需要重送。";
    if (record.state === "unknown" && !confirmed) return "這筆寫入結果不明，重送可能會重複，需要先確認。";
    record.attempt = 0;
    this.setState(record, "sending", null);
    this.enqueue(record, true);
    return null;
  }

  ignore(id: string): string | null {
    const record = this.records.get(id);
    if (record === undefined) return "沒有這筆寫入。";
    if (!NEEDS_ATTENTION.includes(record.state)) return "這筆寫入不需要忽略。";
    this.setState(record, "ignored", null);
    return null;
  }

  stop(): void {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
  }

  private audit(record: WriteRecord, extra: Record<string, unknown>): void {
    const line = { ts: new Date().toISOString(), write_id: record.id, state: record.state, attempt: record.attempt, ...extra };
    appendLine(this.auditFile, JSON.stringify(line), AUDIT_MODE);
  }

  private setState(record: WriteRecord, state: WriteState, error: string | null, nextAt: number | null = null): void {
    record.state = state;
    record.error = error;
    record.nextAt = nextAt;
    this.audit(record, {
      ...(error === null ? {} : { error }),
      ...(nextAt === null ? {} : { next_at: new Date(nextAt).toISOString() }),
    });
    this.host.onChange();
  }

  private enqueue(record: WriteRecord, reconcileFirst: boolean): void {
    void this.deliver(record, reconcileFirst).catch((error: unknown) => {
      this.setState(record, "failed", `看板內部錯誤：${(error as Error).message}`);
    });
  }

  /**
   * Runs `task` after every earlier command for the same home has finished.
   * Only command execution is serialized; a write waiting for its next retry
   * does not hold up the other writes to that home.
   */
  private exclusive<T>(home: string, task: () => Promise<T>): Promise<T> {
    const previous = this.queues.get(home) ?? Promise.resolve();
    const result = previous.then(task);
    this.queues.set(
      home,
      result.then(
        () => undefined,
        () => undefined,
      ),
    );
    return result;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.timers.delete(timer);
        resolve();
      }, ms);
      this.timers.add(timer);
    });
  }

  /** Runs a write to a final state, waiting out the retry delays in between. */
  private async deliver(record: WriteRecord, reconcileFirst: boolean): Promise<void> {
    let reconcile = reconcileFirst;
    for (;;) {
      const outcome = await this.exclusive(record.home, () => this.attempt(record, reconcile));
      reconcile = true;
      if (outcome.kind !== "retry") {
        this.setState(record, outcome.kind, outcome.kind === "failed" ? outcome.error : null);
        if (outcome.kind === "delivered") this.host.onDelivered(record);
        return;
      }
      const delay = this.timings.retryDelaysMs[record.attempt];
      if (delay === undefined) {
        this.setState(record, "undelivered", outcome.error);
        return;
      }
      record.attempt += 1;
      this.setState(record, "retrying", outcome.error, Date.now() + delay);
      await this.sleep(delay);
    }
  }

  private run(command: WriteCommand): Promise<CommandResult> {
    return this.host.run(command, this.host.secondmates(), this.timings.commandTimeoutMs);
  }

  private async attempt(record: WriteRecord, reconcile: boolean): Promise<Outcome> {
    const { plan } = record;
    switch (plan.type) {
      case "note":
        return noteOutcome(await this.run({ kind: "note", requestId: plan.requestId, body: plan.body }));
      case "send": {
        const result = await this.run({ kind: "send", task: plan.task, text: record.text });
        return result.code === 0 ? { kind: "delivered" } : { kind: "failed", error: errorText(result) };
      }
      case "relay":
        return this.attemptRelay(record, plan);
      case "answer":
        return this.attemptAnswer(record, plan);
      case "tag":
        return this.attemptTag(record, plan, reconcile);
    }
  }

  private async attemptRelay(record: WriteRecord, plan: Extract<WritePlan, { type: "relay" }>): Promise<Outcome> {
    const text = `轉給 ${record.task ?? ""}：${record.text}`;
    const result = await this.run({ kind: "relay", secondmate: plan.secondmate, deliveryId: plan.deliveryId, text });
    if (result.code === 0) return { kind: "delivered" };
    // Exit 3: fm-send.sh retried once and the remote delivery is still unconfirmed.
    if (result.code === 3 && plan.remote) return { kind: "retry", error: errorText(result) };
    return { kind: "failed", error: errorText(result) };
  }

  /** An answer is two steps: record it on the hold, then tell firstmate. The note waits for the answer. */
  private async attemptAnswer(record: WriteRecord, plan: Extract<WritePlan, { type: "answer" }>): Promise<Outcome> {
    if (!plan.answered) {
      const command: WriteCommand = { kind: "answer", placement: plan.placement, line: plan.line, ...secondmateOf(record) };
      const outcome = answerOutcome(await this.run(command), record.task ?? "", plan.placement === "remote");
      if (outcome !== "closed") return outcome;
      plan.answered = true;
      this.audit(record, { step: "answered" });
    }
    return noteOutcome(await this.run({ kind: "note", requestId: `tb-${record.id}-note`, body: plan.noteBody }));
  }

  /**
   * Tags a task. Before any attempt after the first, the home is read afresh:
   * the tag may already be in place, or someone else may have tagged the task
   * with another topic since, in which case it is left alone.
   */
  private async attemptTag(
    record: WriteRecord,
    plan: Extract<WritePlan, { type: "tag" }>,
    reconcile: boolean,
  ): Promise<Outcome> {
    if (reconcile) {
      const tags = await this.host.readTags(record.home, plan.task);
      if (tags === null) return { kind: "retry", error: "對帳時讀不到那個 home。" };
      const current = lastLine(tags);
      if (current.split(" ")[0] === plan.topic) return { kind: "delivered" };
      if (current !== plan.lastLineAtSend) return { kind: "handled_elsewhere" };
    }
    const command: WriteCommand = { kind: "tag", placement: plan.placement, task: plan.task, topic: plan.topic, ...secondmateOf(record) };
    const result = await this.run(command);
    if (result.code === 0) return { kind: "delivered" };
    if (plan.placement === "remote" && result.code === 255) return { kind: "retry", error: errorText(result) };
    return { kind: "failed", error: errorText(result) };
  }

  private replay(line: string): void {
    const entry = parseAuditLine(line);
    if (entry === null) return;
    const sending = entry.fields["sending"];
    if (isRecord(sending)) this.records.set(entry.id, sending as unknown as WriteRecord);
    const record = this.records.get(entry.id);
    if (record === undefined) return;
    const attempt = entry.fields["attempt"];
    record.state = entry.state;
    record.attempt = typeof attempt === "number" ? attempt : record.attempt;
    record.error = stringField(entry.fields, "error");
    record.nextAt = null;
    if (entry.fields["step"] === "answered" && record.plan.type === "answer") record.plan.answered = true;
  }

  private resume(record: WriteRecord): void {
    if (!isDedupable(record.plan)) {
      this.setState(record, "unknown", "看板在送出途中重啟，不知道有沒有送到。");
    } else if (Date.now() - record.createdAt > this.timings.resumeWindowMs) {
      this.setState(record, "undelivered", "看板重啟時這筆已經放太久，沒有自動接著送。");
    } else {
      this.enqueue(record, true);
    }
  }
}
