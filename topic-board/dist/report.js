// The JSON one home's fm-topic-board-read.sh prints, parsed and checked once
// where it enters the service.
import { isRecord, stringField, stringRecord, textField } from "./files.js";
export const REPORT_SCHEMA = 1;
function records(value) {
    return Array.isArray(value) ? value.filter(isRecord) : [];
}
function strings(value) {
    return Array.isArray(value)
        ? value.filter((entry) => typeof entry === "string")
        : [];
}
const BUCKETS = ["live", "aged", "dated", "blocked"];
function parseHold(raw) {
    const id = stringField(raw, "id");
    const bucket = BUCKETS.find((name) => name === raw["hold_bucket"]);
    if (id === null || bucket === undefined)
        return null;
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
function parseLedger(raw) {
    if (!isRecord(raw))
        return null;
    const status = raw["status"];
    const offset = raw["to_offset"];
    const sha = stringField(raw, "to_prefix_sha256");
    if (status !== "delta" && status !== "continuity-broken" && status !== "absent")
        return null;
    if (typeof offset !== "number" || sha === null)
        return null;
    return {
        status,
        to_offset: offset,
        to_prefix_sha256: sha,
        more: raw["more"] === true,
        lines: strings(raw["lines"]),
    };
}
/** Builds an entry from a record that must carry a string `id`. */
function withId(raw, build) {
    const id = stringField(raw, "id");
    return id === null ? null : build(id);
}
/** A task's crew state; a report that omits it means the state is not known. */
function stateOf(raw) {
    const state = stringField(raw, "state");
    return state === null ? "unknown" : state;
}
function parseTask(raw) {
    return withId(raw, (id) => ({
        id,
        kind: textField(raw, "kind"),
        state: stateOf(raw),
        source: textField(raw, "source"),
        detail: textField(raw, "detail"),
        unstarted: raw["unstarted"] === true,
    }));
}
function parseQueued(raw) {
    return withId(raw, (id) => ({
        id,
        kind: textField(raw, "kind"),
        title: textField(raw, "title"),
        hold: stringField(raw, "hold"),
        captain: raw["captain"] === true,
        blockers: strings(raw["blockers"]),
        topic_hint: stringField(raw, "topic_hint"),
    }));
}
function parseSecondmate(raw) {
    return withId(raw, (id) => ({
        id,
        remote: raw["remote"] === true,
        home: textField(raw, "home"),
    }));
}
function parseQuestion(raw) {
    return withId(raw, (id) => ({
        id,
        key: textField(raw, "key"),
        summary: textField(raw, "summary"),
    }));
}
function present(value) {
    return value !== null;
}
export function parseReport(stdout) {
    let raw;
    try {
        raw = JSON.parse(stdout);
    }
    catch {
        return { kind: "invalid" };
    }
    if (!isRecord(raw))
        return { kind: "invalid" };
    if (raw["schema"] !== REPORT_SCHEMA)
        return { kind: "incompatible" };
    const ledger = parseLedger(raw["ledger"]);
    if (ledger === null)
        return { kind: "invalid" };
    return {
        kind: "ok",
        report: {
            code_commit: textField(raw, "code_commit"),
            ledger_enabled: raw["ledger_enabled"] === true,
            tasks: records(raw["tasks"]).map(parseTask).filter(present),
            queued: records(raw["queued"]).map(parseQueued).filter(present),
            holds: records(raw["holds"]).map(parseHold).filter(present),
            status_decisions: records(raw["status_decisions"]).map(parseQuestion).filter(present),
            topics: stringRecord(raw["topics"]),
            ledger,
            secondmates: records(raw["secondmates"]).map(parseSecondmate).filter(present),
        },
    };
}
