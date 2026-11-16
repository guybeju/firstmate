// Looks up where a topic or task is now and how it got there, from the
// history kept in the topic file. Pure, and bounded: the answer is meant to be
// read by firstmate without filling its context.
import { QUEUES, resolveTopicId } from "./topics.js";
const MAX_TOPICS = 5;
const MAX_HISTORY = 8;
const QUEUE_LABEL = { high: "高", normal: "一般", later: "待辦" };
function nameOf(state, id) {
    return state.doc.topics[id]?.name ?? state.archive.topics[id]?.name ?? null;
}
function placeOf(state, id) {
    if (state.archive.topics[id] !== undefined)
        return "已封存";
    const topic = state.doc.topics[id];
    if (topic === undefined)
        return "已不存在";
    if (topic.status === "proposed")
        return "提議中";
    const queue = QUEUES.find((name) => state.doc.queues[name].includes(id));
    return queue === undefined ? "沒有排進佇列" : QUEUE_LABEL[queue];
}
function describe(entry) {
    const day = entry.at.slice(0, 10);
    switch (entry.kind) {
        case "merged":
            return `${day} 「${entry.from_name ?? ""}」（${entry.from ?? ""}）併入「${entry.name}」`;
        case "renamed":
            return `${day} 「${entry.from_name ?? ""}」改名為「${entry.name}」`;
        case "split":
            return `${day} 從「${entry.from_name ?? ""}」（${entry.from ?? ""}）拆出「${entry.name}」（${entry.topic}）`;
        case "archived":
            return `${day} 封存`;
        case "reopened":
            return `${day} 重開`;
    }
}
/** True when the entry is part of how `id` came to be what it is. */
function concerns(state, entry, id) {
    if (resolveTopicId(state.doc, entry.topic) === id)
        return true;
    return entry.from !== undefined && resolveTopicId(state.doc, entry.from) === id;
}
function matches(needle, ...texts) {
    return texts.some((text) => text !== undefined && text.toLowerCase().includes(needle));
}
/** Current ids of every topic the query touches: by id, name, goal, an old id, or an old name. */
function matchingTopics(state, needle) {
    const found = new Set();
    for (const topics of [state.doc.topics, state.archive.topics]) {
        for (const [id, topic] of Object.entries(topics)) {
            if (matches(needle, id, topic.name, topic.goal))
                found.add(id);
        }
    }
    for (const old of Object.keys(state.doc.merged)) {
        if (matches(needle, old))
            found.add(resolveTopicId(state.doc, old));
    }
    for (const entry of state.doc.history) {
        if (matches(needle, entry.name, entry.from_name))
            found.add(resolveTopicId(state.doc, entry.topic));
    }
    return [...found];
}
function topicLines(state, id) {
    const history = state.doc.history.filter((entry) => concerns(state, entry, id));
    const recorded = new Set(history.filter((entry) => entry.kind === "merged").map((entry) => entry.from));
    const unrecorded = Object.keys(state.doc.merged).filter((old) => resolveTopicId(state.doc, old) === id && !recorded.has(old));
    const older = history.length - MAX_HISTORY;
    return [
        `${id}　${nameOf(state, id) ?? ""}（${placeOf(state, id)}）`,
        ...(older > 0 ? [`  還有 ${older} 筆更早的紀錄`] : []),
        ...history.slice(-MAX_HISTORY).map((entry) => `  ${describe(entry)}`),
        ...unrecorded.map((old) => `  ${old} 併入這裡（沒有當時的紀錄）`),
    ];
}
function taskLine(state, entry) {
    const steps = entry.tags.map((tag) => {
        const id = resolveTopicId(state.doc, tag.topic);
        const name = nameOf(state, id);
        if (name === null)
            return `${tag.topic}（不認得的議題）`;
        const day = new Date(tag.atMs).toISOString().slice(0, 10);
        return `${name}（${day}${tag.topic === id ? "" : `，原 ${tag.topic}`}）`;
    });
    const path = steps.length === 0 ? "沒有標過議題" : steps.join("→ ");
    return `task ${entry.home}/${entry.task}：${path}`;
}
/**
 * Answers "where is this now, and what happened to it" for a query.
 *
 * Args:
 *   state: The topics, their archive, and their history.
 *   query: Plain text matched, ignoring case, against topic ids, names, and
 *     goals, including ids and names that no longer exist.
 *   tasks: Tag files of the tasks whose id is the query, already looked up.
 *
 * Returns:
 *   A few lines for firstmate: one per task, then each matching topic under
 *   its current id with its history. Never empty.
 */
export function findLines(state, query, tasks) {
    const needle = query.trim().toLowerCase();
    const ids = matchingTopics(state, needle);
    const lines = [
        ...tasks.map((entry) => taskLine(state, entry)),
        ...ids.slice(0, MAX_TOPICS).flatMap((id) => topicLines(state, id)),
    ];
    if (ids.length > MAX_TOPICS)
        lines.push(`還有 ${ids.length - MAX_TOPICS} 個議題符合，請用更長的關鍵字。`);
    return lines.length === 0 ? [`找不到「${query.trim()}」。`] : lines;
}
