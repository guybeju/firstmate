// The four things the captain can send from the board, checked and turned into
// writes. The socket's test ops and the browser API both come through here.
import crypto from "node:crypto";
import { directTextProblem } from "./commands.js";
import { MAIN_HOME } from "./journal.js";
import { resolveTopicId } from "./topics.js";
import { answerOutcome, placeTask } from "./view.js";
const TASK_ID = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/;
const MESSAGE_MAX = 4000;
const ANSWER_MAX = 1000;
function refuse(line) {
    return { ok: false, line };
}
function topicName(topics, id) {
    return topics.doc.topics[id]?.name ?? topics.archive.topics[id]?.name ?? null;
}
/** Where commands for `home` run, or null when the board does not know that home. */
function placementOf(context, home) {
    if (home === MAIN_HOME)
        return "main";
    const secondmate = context.secondmates.find((entry) => entry.id === home);
    if (secondmate === undefined)
        return null;
    return secondmate.remote ? "remote" : "local";
}
function lengthOf(text) {
    return [...text].length;
}
/** A message from a topic page to the main firstmate. */
export function message(context, rawTopic, text, channel) {
    const topic = resolveTopicId(context.topics.doc, rawTopic);
    const name = topicName(context.topics, topic);
    if (name === null)
        return refuse(`沒有 ${rawTopic} 這個議題。`);
    const body = text.trim();
    if (body === "" || lengthOf(body) > MESSAGE_MAX)
        return refuse(`訊息要有內容，而且最多 ${MESSAGE_MAX} 個字。`);
    return {
        ok: true,
        write: context.writes.submit({
            channel,
            home: MAIN_HOME,
            task: null,
            topic,
            text: body,
            plan: {
                type: "note",
                requestId: `tb-${crypto.randomBytes(8).toString("hex")}`,
                body: `［議題：${name}（${topic}）］\n${body}`,
            },
        }),
    };
}
/** Checks the home and task every agent-directed action names. */
function agentTarget(context, home, task) {
    const placement = placementOf(context, home);
    if (placement === null)
        return refuse(`不認得 home ${home}。`);
    return TASK_ID.test(task) ? placement : refuse(`task id 格式不對：${task}`);
}
/** Why `text` cannot be sent to an agent, or null when it can. */
function directProblem(text) {
    const problem = directTextProblem(text);
    if (problem !== null)
        return problem;
    return lengthOf(text) > MESSAGE_MAX ? `訊息最多 ${MESSAGE_MAX} 個字。` : null;
}
/** A message straight to one agent: written to a main-home worker, relayed by its secondmate otherwise. */
export function direct(context, home, task, text, channel) {
    const placement = agentTarget(context, home, task);
    if (typeof placement !== "string")
        return placement;
    const problem = directProblem(text);
    if (problem !== null)
        return refuse(problem);
    const topic = placeTask(context.topics, context.homes, home, task).topic;
    const plan = placement === "main"
        ? { type: "send", task }
        : {
            type: "relay",
            secondmate: home,
            remote: placement === "remote",
            deliveryId: crypto.randomBytes(8).toString("hex"),
        };
    return { ok: true, write: context.writes.submit({ channel, home, task, topic, text, plan }) };
}
function oneLineProblem(what, text) {
    if (text.trim() === "" || lengthOf(text) > ANSWER_MAX)
        return `${what}要有內容，而且最多 ${ANSWER_MAX} 個字。`;
    return /[\t\r\n]/.test(text) ? `${what}只能有一行，而且不能有 tab。` : null;
}
/** What `home` last reported, or null when the board has no report for it. */
function reportOf(context, home) {
    const snapshot = context.homes.find((entry) => entry.id === home);
    return snapshot === undefined ? null : snapshot.report;
}
/** The captain hold on `task` in `home`, as last reported. */
export function findHold(context, home, task) {
    const report = reportOf(context, home);
    return report === null ? undefined : report.holds.find((entry) => entry.id === task);
}
/** The name to show for a topic id; "未分類" when there is none. */
function topicLabel(topics, topic) {
    if (topic === null)
        return "未分類";
    const name = topicName(topics, topic);
    return name === null ? topic : name;
}
/** The last line of a task's tag file as its home last reported it. */
function lastTagLine(context, home, task) {
    const report = reportOf(context, home);
    const tags = report === null ? undefined : report.topics[task];
    if (tags === undefined)
        return "";
    const lines = tags.trimEnd().split("\n");
    return lines[lines.length - 1];
}
/** The topic a hold belongs to: its own task's, else its origin task's, else none. */
function holdTopic(context, home, task, origin) {
    const own = placeTask(context.topics, context.homes, home, task).topic;
    if (own !== null || origin === "")
        return own;
    return placeTask(context.topics, context.homes, home, origin).topic;
}
/** The close mode fm-captain-hold.sh answers takes for what answering `hold` does. */
export function answerMode(home, hold) {
    return answerOutcome(home, hold).on_answer === "close" ? "done" : "release";
}
/** An answer to a captain hold, closing or releasing it as the hold recorded, followed by a note telling firstmate. */
export function answer(context, input, channel) {
    const placement = agentTarget(context, input.home, input.task);
    if (typeof placement !== "string")
        return placement;
    const hold = findHold(context, input.home, input.task);
    if (hold === undefined)
        return refuse(`${input.home}/${input.task} 沒有等你回答的待決事項（可能已經有人答了）。`);
    const answerProblem = oneLineProblem("答案", input.answer);
    if (answerProblem !== null)
        return refuse(answerProblem);
    const labelProblem = oneLineProblem("選項", input.label);
    if (labelProblem !== null)
        return refuse(labelProblem);
    const topic = holdTopic(context, input.home, input.task, hold.origin);
    const name = topicLabel(context.topics, topic);
    return {
        ok: true,
        write: context.writes.submit({
            channel,
            home: input.home,
            task: input.task,
            topic,
            text: input.answer,
            plan: {
                type: "answer",
                placement,
                line: [input.task, input.answer, input.label, answerMode(input.home, hold)].join("\t"),
                noteBody: `［議題：${name}］已在看板回答 ${input.home}/${input.task}：${input.answer}`,
                answered: false,
            },
        }),
    };
}
/** Files an agent under a confirmed topic by tagging its task in the home it lives in. */
export function tagAgent(context, home, task, rawTopic, channel) {
    const placement = agentTarget(context, home, task);
    if (typeof placement !== "string")
        return placement;
    const topic = resolveTopicId(context.topics.doc, rawTopic);
    if (context.topics.doc.topics[topic]?.status !== "confirmed")
        return refuse(`${rawTopic} 不是已確認的議題。`);
    return {
        ok: true,
        write: context.writes.submit({
            channel,
            home,
            task,
            topic,
            text: `歸到「${topicLabel(context.topics, topic)}」`,
            plan: {
                type: "tag",
                placement,
                task,
                topic,
                lastLineAtSend: lastTagLine(context, home, task),
            },
        }),
    };
}
