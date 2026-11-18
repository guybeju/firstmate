// Loads and saves the topic files. The service is their only writer.
import fs from "node:fs";
import { isRecord, readJsonFile, stringField, stringRecord, textField, writeFileAtomic, } from "./files.js";
import { GOAL_MAX, HISTORY_ACTORS, HISTORY_KINDS, QUEUES, TODO_STATES, emptyState, isQueue, oneLine, } from "./topics.js";
const FILE_MODE = 0o644;
function parseCloseProposal(raw) {
    if (!isRecord(raw) || typeof raw["at"] !== "string" || typeof raw["reason"] !== "string")
        return undefined;
    return { at: raw["at"], reason: raw["reason"] };
}
function parseTopic(id, raw) {
    if (!isRecord(raw))
        throw new Error(`topic ${id} is not an object`);
    const { name, goal, status } = raw;
    if (typeof name !== "string" || typeof goal !== "string")
        throw new Error(`topic ${id} lacks name or goal`);
    if (status !== "proposed" && status !== "confirmed")
        throw new Error(`topic ${id} has an unknown status`);
    const topic = {
        name,
        goal,
        status: "confirmed",
        created_at: textField(raw, "created_at"),
    };
    const close = parseCloseProposal(raw["close_proposal"]);
    if (close !== undefined)
        topic.close_proposal = close;
    const suggested = raw["suggested_queue"];
    const proposedFor = status === "confirmed" ? null : isQueue(suggested) ? suggested : "normal";
    return { topic, proposedFor };
}
/** A queue holds topics that were already confirmed on disk, each once. */
function parseQueue(raw, confirmed) {
    if (!Array.isArray(raw))
        return [];
    return [...new Set(raw)].filter((id) => typeof id === "string" && confirmed.has(id));
}
function parseNextSeq(raw) {
    return typeof raw === "number" && Number.isInteger(raw) ? Math.max(1, raw) : 1;
}
function parseHistoryEntry(raw) {
    if (!isRecord(raw))
        return null;
    const kind = HISTORY_KINDS.find((name) => name === raw["kind"]);
    const at = stringField(raw, "at");
    const topic = stringField(raw, "topic");
    const name = stringField(raw, "name");
    if (kind === undefined || at === null || topic === null || name === null)
        return null;
    const entry = { at, kind, topic, name };
    const from = stringField(raw, "from");
    const fromName = stringField(raw, "from_name");
    if (from !== null)
        entry.from = from;
    if (fromName !== null)
        entry.from_name = fromName;
    // A reason someone edited into something that is not one line is dropped, not printed.
    const reason = oneLine(stringField(raw, "reason") ?? "", GOAL_MAX);
    const by = HISTORY_ACTORS.find((actor) => actor === raw["by"]);
    if (reason !== null)
        entry.reason = reason;
    if (by !== undefined)
        entry.by = by;
    return entry;
}
function parseHistory(raw) {
    if (!Array.isArray(raw))
        return [];
    return raw.map(parseHistoryEntry).filter((entry) => entry !== null);
}
function parseTodos(raw) {
    const todos = {};
    if (!isRecord(raw))
        return todos;
    for (const [task, value] of Object.entries(raw)) {
        if (!isRecord(value) || task === "__proto__")
            continue;
        const state = TODO_STATES.find((name) => name === value["state"]);
        const at = stringField(value, "at");
        if (state === undefined || at === null)
            continue;
        const reason = stringField(value, "reason");
        todos[task] = reason === null ? { state, at } : { state, at, reason };
    }
    return todos;
}
/**
 * Reads the live topics. A leftover proposal is confirmed here, at the end of
 * the queue it was proposed for, so no topic is ever left waiting.
 */
function parseDoc(raw) {
    if (!isRecord(raw) || raw["v"] !== 1)
        throw new Error("expected an object with v: 1");
    const topics = raw["topics"];
    if (!isRecord(topics))
        throw new Error("topics is not an object");
    const doc = emptyState().doc;
    // Keyed by creation time, then id, so sorting the keys puts the oldest first.
    const waiting = new Map();
    const confirmed = new Set();
    for (const [id, value] of Object.entries(topics)) {
        const { topic, proposedFor } = parseTopic(id, value);
        doc.topics[id] = topic;
        if (proposedFor === null)
            confirmed.add(id);
        else
            waiting.set(`${topic.created_at}\u0000${id}`, { id, name: topic.name, queue: proposedFor });
    }
    const queues = isRecord(raw["queues"]) ? raw["queues"] : {};
    for (const queue of QUEUES)
        doc.queues[queue] = parseQueue(queues[queue], confirmed);
    const oldestFirst = [...waiting.keys()].sort().map((key) => waiting.get(key));
    for (const proposal of oldestFirst)
        doc.queues[proposal.queue].push(proposal.id);
    doc.merged = stringRecord(raw["merged"]);
    doc.history = parseHistory(raw["history"]);
    doc.todos = parseTodos(raw["todos"]);
    doc.next_seq = parseNextSeq(raw["next_seq"]);
    return { doc, confirmed: oldestFirst };
}
function parseArchive(raw) {
    if (!isRecord(raw) || raw["v"] !== 1 || !isRecord(raw["topics"])) {
        throw new Error("expected an object with v: 1 and topics");
    }
    const archive = { v: 1, topics: {} };
    let hadProposals = false;
    for (const [id, value] of Object.entries(raw["topics"])) {
        const { topic, proposedFor } = parseTopic(id, value);
        if (proposedFor !== null)
            hadProposals = true;
        const archived = {
            ...topic,
            archived_at: textField(value, "archived_at"),
        };
        archive.topics[id] = archived;
    }
    return { archive, hadProposals };
}
function loadFile(file, parse, fallback) {
    let raw;
    try {
        raw = readJsonFile(file);
    }
    catch (error) {
        throw new Error(`${file} 讀不懂：${error.message}`, { cause: error });
    }
    if (raw === null)
        return fallback;
    try {
        return parse(raw);
    }
    catch (error) {
        throw new Error(`${file} 讀不懂：${error.message}`, { cause: error });
    }
}
/**
 * Loads both topic files. Leftover proposals are confirmed at the end of the
 * queue each was proposed for (normal when it named none), oldest first, and
 * the files are rewritten at once, so the commands that read the files
 * directly see the same topics as the board.
 */
export function loadTopicState(paths) {
    const empty = emptyState();
    const live = loadFile(paths.topics, parseDoc, { doc: empty.doc, confirmed: [] });
    const gone = loadFile(paths.archive, parseArchive, {
        archive: empty.archive,
        hadProposals: false,
    });
    const state = { doc: live.doc, archive: gone.archive };
    // A crash between the two writes of an archive or reopen can leave a topic in
    // both files. The live copy wins: an interrupted archive is simply redone,
    // and an interrupted reopen is already complete.
    for (const id of Object.keys(state.archive.topics)) {
        if (state.doc.topics[id] !== undefined)
            delete state.archive.topics[id];
    }
    // A proposal was read from one of these files, so their directory exists.
    if (gone.hadProposals)
        writeFileAtomic(paths.archive, serialize(state.archive), FILE_MODE);
    if (live.confirmed.length > 0)
        writeFileAtomic(paths.topics, serialize(state.doc), FILE_MODE);
    return { state, confirmed: live.confirmed };
}
function serialize(value) {
    return `${JSON.stringify(value, null, 2)}\n`;
}
/** Writes whichever of the two files changed, the file gaining a topic first. */
export function saveTopicState(paths, previous, next) {
    fs.mkdirSync(paths.dataDir, { recursive: true });
    const docText = serialize(next.doc);
    const archiveText = serialize(next.archive);
    const writeDoc = () => {
        if (docText !== serialize(previous.doc))
            writeFileAtomic(paths.topics, docText, FILE_MODE);
    };
    const writeArchive = () => {
        if (archiveText !== serialize(previous.archive))
            writeFileAtomic(paths.archive, archiveText, FILE_MODE);
    };
    const archiveGained = Object.keys(next.archive.topics).some((id) => previous.archive.topics[id] === undefined);
    if (archiveGained) {
        writeArchive();
        writeDoc();
    }
    else {
        writeDoc();
        writeArchive();
    }
}
