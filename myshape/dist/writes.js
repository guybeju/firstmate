// Everything the board hands the aggregator on the captain's behalf: messages,
// direct messages to agents, answers to decisions, filings under a topic, and
// notices of what happened on the board. Each write is one action record
// (contracts section 7.2), recorded in the audit log before it runs and at
// every state change, retried only when the deliverer says so, and resumed
// after a restart from the audit log alone. While the deliverer cannot be
// started, writes wait and are handed over in record order at the next start.
import crypto from "node:crypto";
import { appendLine, isRecord, readCompleteLines, stringField } from "./files.js";
import { legacyRecord } from "./legacy.js";
export const DEFAULT_WRITE_TIMINGS = {
    retryDelaysMs: [10_000, 30_000, 60_000, 300_000, 900_000],
    resumeWindowMs: 30 * 60_000,
    commandTimeoutMs: 400_000,
};
const AUDIT_MODE = 0o600;
const ERROR_MAX = 600;
const UNFINISHED = ["sending", "retrying"];
export const NEEDS_ATTENTION = ["failed", "undelivered", "unknown"];
const OUTCOMES = ["delivered", "handled_elsewhere", "retry", "failed"];
function errorText(result) {
    return (result.stderr.trim() || result.stdout.trim() || `exit ${result.code ?? "?"}`).slice(0, ERROR_MAX);
}
/** The deliverer's outcome: its last stdout line; anything else is a failure with its stderr. */
export function parseOutcome(result) {
    const lines = result.stdout.split("\n").filter((line) => line.trim() !== "");
    let parsed = null;
    try {
        parsed = JSON.parse(lines[lines.length - 1] ?? "");
    }
    catch {
        parsed = null;
    }
    const outcome = isRecord(parsed) ? parsed["outcome"] : undefined;
    if (typeof outcome !== "string" || !OUTCOMES.includes(outcome))
        return { kind: "failed", error: errorText(result) };
    if (outcome === "delivered" || outcome === "handled_elsewhere")
        return { kind: outcome };
    const error = isRecord(parsed) ? stringField(parsed, "error") : null;
    return {
        kind: outcome,
        error: (error ?? errorText(result)).slice(0, ERROR_MAX),
    };
}
/** True when handing the same record over again cannot make it take effect twice. */
export function isDedupable(action) {
    return action.kind !== "direct";
}
/** The one line the deliverer reads on stdin. */
export function actionRecord(record) {
    return JSON.stringify({ v: 1, id: record.id, attempt: record.attempt, ...record.action });
}
function lastLine(text) {
    const lines = text.trimEnd().split("\n");
    return lines[lines.length - 1];
}
/** One audit line about a write; lines about rejected requests carry no write id and yield null. */
function parseAuditLine(line) {
    let entry;
    try {
        entry = JSON.parse(line);
    }
    catch {
        return null;
    }
    if (!isRecord(entry))
        return null;
    const id = stringField(entry, "write_id");
    const state = stringField(entry, "state");
    return id === null || state === null ? null : { id, state, fields: entry };
}
export class WriteEngine {
    auditFile;
    host;
    timings;
    records = new Map();
    queues = new Map();
    timers = new Set();
    constructor(auditFile, host, timings) {
        this.auditFile = auditFile;
        this.host = host;
        this.timings = timings;
        for (const line of readCompleteLines(this.auditFile))
            this.replay(line);
    }
    /** True when writes go to the deliverer; false when they wait for the next start. */
    get connected() {
        return this.host.unavailable === null;
    }
    /**
     * Hands over, in record order, every write a restart left waiting or
     * unfinished. Called once, before the service answers anyone, so nothing
     * submitted afterwards can overtake them.
     */
    resumeUnfinished() {
        for (const record of this.records.values()) {
            if (record.state === "waiting") {
                if (this.connected)
                    this.release(record);
            }
            else if (UNFINISHED.includes(record.state)) {
                this.resume(record);
            }
        }
    }
    /** Records a new write and starts delivering it, or leaves it waiting. */
    submit(input) {
        const record = {
            ...input,
            id: `w-${Date.now().toString(36)}-${crypto.randomBytes(3).toString("hex")}`,
            state: this.connected ? "sending" : "waiting",
            attempt: 0,
            error: null,
            nextAt: null,
            createdAt: Date.now(),
        };
        this.records.set(record.id, record);
        this.audit(record, { sending: record });
        if (this.connected)
            this.enqueue(record, false);
        return record;
    }
    /** Sends a failed write again under the same id. */
    resend(id, confirmed) {
        const record = this.records.get(id);
        if (record === undefined)
            return "沒有這筆寫入。";
        if (!NEEDS_ATTENTION.includes(record.state))
            return "這筆寫入不需要重送。";
        if (record.state === "unknown" && !confirmed)
            return "這筆寫入結果不明，重送可能會重複，需要先確認。";
        record.attempt = 0;
        if (!this.connected) {
            this.setState(record, "waiting", null);
            return null;
        }
        this.setState(record, "sending", null);
        this.enqueue(record, true);
        return null;
    }
    ignore(id) {
        const record = this.records.get(id);
        if (record === undefined)
            return "沒有這筆寫入。";
        if (!NEEDS_ATTENTION.includes(record.state))
            return "這筆寫入不需要忽略。";
        this.setState(record, "ignored", null);
        return null;
    }
    stop() {
        for (const timer of this.timers)
            clearTimeout(timer);
        this.timers.clear();
    }
    audit(record, extra) {
        const line = {
            ts: new Date().toISOString(),
            write_id: record.id,
            state: record.state,
            attempt: record.attempt,
            ...extra,
        };
        appendLine(this.auditFile, JSON.stringify(line), AUDIT_MODE);
    }
    setState(record, state, error, nextAt = null) {
        record.state = state;
        record.error = error;
        record.nextAt = nextAt;
        this.audit(record, {
            ...(error === null ? {} : { error }),
            ...(nextAt === null ? {} : { next_at: new Date(nextAt).toISOString() }),
        });
        this.host.onChange();
    }
    enqueue(record, reconcileFirst) {
        void this.deliver(record, reconcileFirst).catch((error) => {
            this.setState(record, "failed", `看板內部錯誤：${error.message}`);
        });
    }
    /**
     * Runs `task` after every earlier run for the same home has finished. Only
     * runs are serialized; a write waiting for its next retry does not hold up
     * the other writes to that home.
     */
    exclusive(home, task) {
        const queued = this.queues.get(home);
        const previous = queued === undefined ? Promise.resolve() : queued;
        const result = previous.then(task);
        this.queues.set(home, result.then(() => undefined, () => undefined));
        return result;
    }
    sleep(ms) {
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                this.timers.delete(timer);
                resolve();
            }, ms);
            this.timers.add(timer);
        });
    }
    /** Runs a write to a final state, waiting out the retry delays in between. */
    async deliver(record, reconcileFirst) {
        let reconcile = reconcileFirst;
        for (;;) {
            const outcome = await this.exclusive(record.home, () => this.attempt(record, reconcile));
            reconcile = true;
            if (outcome.kind !== "retry") {
                this.setState(record, outcome.kind, outcome.kind === "failed" ? outcome.error : null);
                if (outcome.kind === "delivered")
                    this.host.onDelivered(record);
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
    async attempt(record, reconcile) {
        if (record.action.kind === "tag" && reconcile) {
            const settled = await this.reconcileTag(record.action);
            if (settled !== null)
                return settled;
        }
        const result = await this.host.run({ kind: "deliver", record: actionRecord(record) }, this.timings.commandTimeoutMs);
        return parseOutcome(result);
    }
    /**
     * Before any attempt to file a task after the first, the home is read
     * afresh: the tag may already be in place, or someone else may have filed
     * the task under another topic since, in which case it is left alone.
     */
    async reconcileTag(action) {
        const tags = await this.host.readTags(action.home, action.task);
        if (tags === null)
            return { kind: "retry", error: "對帳時讀不到那個 home。" };
        const current = lastLine(tags);
        if (current.split(" ")[0] === action.topic)
            return { kind: "delivered" };
        return current === action.last_tag_line ? null : { kind: "handled_elsewhere" };
    }
    replay(line) {
        const entry = parseAuditLine(line);
        if (entry === null)
            return;
        const sending = entry.fields["sending"];
        if (isRecord(sending)) {
            const record = isRecord(sending["action"])
                ? sending
                : legacyRecord(sending);
            if (record !== null)
                this.records.set(entry.id, record);
        }
        const record = this.records.get(entry.id);
        if (record === undefined)
            return;
        const attempt = entry.fields["attempt"];
        record.state = entry.state;
        record.attempt = typeof attempt === "number" ? attempt : record.attempt;
        record.error = stringField(entry.fields, "error");
        record.nextAt = null;
    }
    /** A waiting write never ran: it starts from attempt 0 whatever its age. */
    release(record) {
        record.attempt = 0;
        this.setState(record, "sending", null);
        this.enqueue(record, false);
    }
    resume(record) {
        if (!isDedupable(record.action)) {
            this.setState(record, "unknown", "看板在送出途中重啟，不知道有沒有送到。");
        }
        else if (Date.now() - record.createdAt > this.timings.resumeWindowMs) {
            this.setState(record, "undelivered", "看板重啟時這筆已經放太久，沒有自動接著送。");
        }
        else if (!this.connected) {
            this.setState(record, "waiting", null);
        }
        else {
            this.enqueue(record, true);
        }
    }
}
