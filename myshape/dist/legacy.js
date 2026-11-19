// The one-time reading of audit lines a board wrote before action records
// existed. Those writes carry a plan named by type (note, send, relay, answer,
// tag) instead of an action; each is turned into the action that does the
// same, keeping its write id, so an unfinished one still resumes and a settled
// one still shows in the history. To be removed once no audit file can hold
// such lines (design B4).
import { isRecord, stringField, textField } from "./files.js";
const MAIN_HOME = "main";
/** The name inside a note's 「［議題：<name>（<id>）］」 or 「［議題：<name>］」 prefix. */
function nameInPrefix(body) {
    const match = /^［議題：(.*?)(?:（[^（）]*）)?］/.exec(body);
    return match === null ? null : match[1];
}
/** Which notice an old note was, from the request-id prefix it was sent with. */
function noticeEvent(requestId, body) {
    if (requestId.startsWith("tb-dispatch-"))
        return "topic.dispatchable";
    if (requestId.startsWith("tb-confirmed-"))
        return "topic.confirmed";
    if (!requestId.startsWith("tb-decision-"))
        return null;
    if (body.includes("做完了（"))
        return "todo.claimed";
    if (body.includes("先不關"))
        return "topic.kept";
    return body.includes("已封存") ? "topic.archived" : "topic.merged";
}
function noteAction(plan, topic, text) {
    const requestId = textField(plan, "requestId");
    const body = textField(plan, "body");
    const event = noticeEvent(requestId, body);
    if (event !== null)
        return { kind: "notice", event, text: body, legacy_request_id: requestId };
    const id = topic ?? "";
    return {
        kind: "message",
        topic: { id, name: nameInPrefix(body) ?? id },
        text,
        legacy_request_id: requestId,
    };
}
function answerAction(plan, home, topic) {
    const [task = "", answer = "", label = "", mode = ""] = textField(plan, "line").split("\t");
    const name = nameInPrefix(textField(plan, "noteBody"));
    return {
        kind: "answer",
        home,
        task,
        answer,
        label,
        mode: mode === "done" ? "done" : "release",
        question_sha256: "-",
        topic: topic === null ? null : { id: topic, name: name ?? topic },
    };
}
function actionOf(raw, plan) {
    const home = textField(raw, "home") || MAIN_HOME;
    const task = textField(raw, "task");
    const topic = stringField(raw, "topic");
    const text = textField(raw, "text");
    switch (plan["type"]) {
        case "note":
            return noteAction(plan, topic, text);
        case "send":
            return { kind: "direct", home: MAIN_HOME, task, text };
        case "relay":
            return { kind: "direct", home: textField(plan, "secondmate") || home, task, text };
        case "answer":
            return answerAction(plan, home, topic);
        case "tag":
            return {
                kind: "tag",
                home,
                task: textField(plan, "task"),
                topic: textField(plan, "topic"),
                last_tag_line: textField(plan, "lastLineAtSend"),
            };
        default:
            return null;
    }
}
/** The write an old audit line's "sending" record describes, or null when it is not one. */
export function legacyRecord(raw) {
    const plan = raw["plan"];
    const id = stringField(raw, "id");
    if (!isRecord(plan) || id === null)
        return null;
    const action = actionOf(raw, plan);
    if (action === null)
        return null;
    const channel = raw["channel"];
    const createdAt = raw["createdAt"];
    return {
        id,
        channel: channel === "browser" || channel === "socket" ? channel : "auto",
        home: action.kind === "direct" ? action.home : textField(raw, "home") || MAIN_HOME,
        task: stringField(raw, "task"),
        topic: stringField(raw, "topic"),
        text: textField(raw, "text"),
        action,
        state: (stringField(raw, "state") ?? "sending"),
        attempt: 0,
        error: null,
        nextAt: null,
        createdAt: typeof createdAt === "number" ? createdAt : 0,
    };
}
