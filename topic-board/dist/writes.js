// Everything the board sends out on the captain's behalf: notes to firstmate,
// direct messages to agents, answers to captain holds, and topic tags. Each
// write is recorded in the audit log before it runs and at every state change,
// retried only when a retry cannot take effect twice, and resumed after a
// restart from the audit log alone.
import crypto from "node:crypto";
import { appendLine, isRecord, readCompleteLines, stringField } from "./files.js";
import { MAIN_HOME } from "./journal.js";
export const DEFAULT_WRITE_TIMINGS = {
    retryDelaysMs: [10_000, 30_000, 60_000, 300_000, 900_000],
    resumeWindowMs: 30 * 60_000,
    commandTimeoutMs: 400_000,
};
const AUDIT_MODE = 0o600;
const UNFINISHED = ["sending", "retrying"];
export const NEEDS_ATTENTION = ["failed", "undelivered", "unknown"];
function errorText(result) {
    return (result.stderr.trim() || result.stdout.trim() || `exit ${result.code ?? "?"}`).slice(0, 600);
}
/** Why fm-send.sh could not deliver, in words for the board; its own text when the cause is not known. */
function sendError(result) {
    const text = errorText(result);
    return text.includes("is not resolvable") ? "這個 worker 已經結束或找不到，訊息沒有送出。" : text;
}
function lastLine(text) {
    const lines = text.trimEnd().split("\n");
    return lines[lines.length - 1];
}
/** True when repeating the write after an unknown outcome cannot make it take effect twice. */
export function isDedupable(plan) {
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
function secondmateOf(record) {
    return record.home === MAIN_HOME ? {} : { secondmate: record.home };
}
function noteOutcome(result) {
    if (result.code === 0)
        return { kind: "delivered" };
    // Exit 3: the note is saved but firstmate was not woken; replaying the same request id wakes it.
    return result.code === 3
        ? { kind: "retry", error: errorText(result) }
        : { kind: "failed", error: errorText(result) };
}
// fm-captain-hold.sh's reasons for skipping a hold that someone already answered or released.
const ANSWERED_ELSEWHERE = [
    "(already closed)",
    "records a different captain decision",
    "(not held for the captain)",
];
/** Reads fm-captain-hold.sh answers output for the line about `task`. */
function answerOutcome(result, task, remote) {
    const lines = result.stdout.split("\n").map((line) => line.trim());
    if (lines.includes(`closed: ${task}`))
        return "closed";
    const verdict = lines.find((line) => line.startsWith(`skipped: ${task} `) || line.startsWith(`refused: ${task} `));
    if (verdict !== undefined && ANSWERED_ELSEWHERE.some((mark) => verdict.includes(mark)))
        return { kind: "handled_elsewhere" };
    if (verdict !== undefined)
        return { kind: "failed", error: verdict };
    if (remote && result.code === 255)
        return { kind: "retry", error: errorText(result) };
    return { kind: "failed", error: errorText(result) };
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
    /**
     * Finishes or settles the writes a restart interrupted. Called once the
     * service is fully built; the main home is read first because relays and
     * remote writes are only allowed to secondmates it lists.
     */
    async resumeUnfinished() {
        const unfinished = [...this.records.values()].filter((record) => UNFINISHED.includes(record.state));
        if (unfinished.length === 0)
            return;
        await this.host.prepare();
        for (const record of unfinished)
            this.resume(record);
    }
    /** Records a new write as "sending" and starts delivering it. */
    submit(input) {
        const record = {
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
    resend(id, confirmed) {
        const record = this.records.get(id);
        if (record === undefined)
            return "沒有這筆寫入。";
        if (!NEEDS_ATTENTION.includes(record.state))
            return "這筆寫入不需要重送。";
        if (record.state === "unknown" && !confirmed)
            return "這筆寫入結果不明，重送可能會重複，需要先確認。";
        record.attempt = 0;
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
     * Runs `task` after every earlier command for the same home has finished.
     * Only command execution is serialized; a write waiting for its next retry
     * does not hold up the other writes to that home.
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
    run(command) {
        return this.host.run(command, this.host.secondmates(), this.timings.commandTimeoutMs);
    }
    async attempt(record, reconcile) {
        const { plan } = record;
        switch (plan.type) {
            case "note":
                return noteOutcome(await this.run({ kind: "note", requestId: plan.requestId, body: plan.body }));
            case "send": {
                const result = await this.run({ kind: "send", task: plan.task, text: record.text });
                return result.code === 0
                    ? { kind: "delivered" }
                    : { kind: "failed", error: sendError(result) };
            }
            case "relay":
                return this.attemptRelay(record, plan);
            case "answer":
                return this.attemptAnswer(record, plan);
            case "tag":
                return this.attemptTag(record, plan, reconcile);
        }
    }
    async attemptRelay(record, plan) {
        const text = `轉給 ${String(record.task)}：${record.text}`;
        const result = await this.run({
            kind: "relay",
            secondmate: plan.secondmate,
            deliveryId: plan.deliveryId,
            text,
        });
        if (result.code === 0)
            return { kind: "delivered" };
        // Exit 3: fm-send.sh retried once and the remote delivery is still unconfirmed.
        if (result.code === 3 && plan.remote)
            return { kind: "retry", error: errorText(result) };
        return { kind: "failed", error: errorText(result) };
    }
    /** An answer is two steps: record it on the hold, then tell firstmate. The note waits for the answer. */
    async attemptAnswer(record, plan) {
        if (!plan.answered) {
            const command = {
                kind: "answer",
                placement: plan.placement,
                line: plan.line,
                ...secondmateOf(record),
            };
            const outcome = answerOutcome(await this.run(command), String(record.task), plan.placement === "remote");
            if (outcome !== "closed")
                return outcome;
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
    async attemptTag(record, plan, reconcile) {
        if (reconcile) {
            const tags = await this.host.readTags(record.home, plan.task);
            if (tags === null)
                return { kind: "retry", error: "對帳時讀不到那個 home。" };
            const current = lastLine(tags);
            if (current.split(" ")[0] === plan.topic)
                return { kind: "delivered" };
            if (current !== plan.lastLineAtSend)
                return { kind: "handled_elsewhere" };
        }
        const command = {
            kind: "tag",
            placement: plan.placement,
            task: plan.task,
            topic: plan.topic,
            ...secondmateOf(record),
        };
        const result = await this.run(command);
        if (result.code === 0)
            return { kind: "delivered" };
        if (plan.placement === "remote" && result.code === 255)
            return { kind: "retry", error: errorText(result) };
        return { kind: "failed", error: errorText(result) };
    }
    replay(line) {
        const entry = parseAuditLine(line);
        if (entry === null)
            return;
        const sending = entry.fields["sending"];
        if (isRecord(sending))
            this.records.set(entry.id, sending);
        const record = this.records.get(entry.id);
        if (record === undefined)
            return;
        const attempt = entry.fields["attempt"];
        record.state = entry.state;
        record.attempt = typeof attempt === "number" ? attempt : record.attempt;
        record.error = stringField(entry.fields, "error");
        record.nextAt = null;
        if (entry.fields["step"] === "answered" && record.plan.type === "answer")
            record.plan.answered = true;
    }
    resume(record) {
        if (!isDedupable(record.plan)) {
            this.setState(record, "unknown", "看板在送出途中重啟，不知道有沒有送到。");
        }
        else if (Date.now() - record.createdAt > this.timings.resumeWindowMs) {
            this.setState(record, "undelivered", "看板重啟時這筆已經放太久，沒有自動接著送。");
        }
        else {
            this.enqueue(record, true);
        }
    }
}
