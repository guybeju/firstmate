// Loads and saves the topic files. The service is their only writer.
import fs from "node:fs";
import { isRecord, readJsonFile, stringField, writeFileAtomic } from "./files.js";
import { QUEUES, emptyState, isQueue } from "./topics.js";
const FILE_MODE = 0o644;
function parseCloseProposal(raw) {
    if (!isRecord(raw) || typeof raw["at"] !== "string" || typeof raw["reason"] !== "string")
        return undefined;
    return { at: raw["at"], reason: raw["reason"] };
}
function parseStatus(id, raw) {
    if (raw !== "proposed" && raw !== "confirmed")
        throw new Error(`topic ${id} has an unknown status`);
    return raw;
}
function parseTopic(id, raw) {
    if (!isRecord(raw))
        throw new Error(`topic ${id} is not an object`);
    const { name, goal } = raw;
    if (typeof name !== "string" || typeof goal !== "string")
        throw new Error(`topic ${id} lacks name or goal`);
    const topic = {
        name,
        goal,
        status: parseStatus(id, raw["status"]),
        created_at: stringField(raw, "created_at") ?? "",
        proposed_by: raw["proposed_by"] === "user" ? "user" : "firstmate",
    };
    if (isQueue(raw["suggested_queue"]))
        topic.suggested_queue = raw["suggested_queue"];
    const close = parseCloseProposal(raw["close_proposal"]);
    if (close !== undefined)
        topic.close_proposal = close;
    return topic;
}
/** A queue only ever holds confirmed topics, each once. */
function parseQueue(raw, topics) {
    if (!Array.isArray(raw))
        return [];
    return [...new Set(raw)].filter((id) => typeof id === "string" && topics[id]?.status === "confirmed");
}
function parseMerged(raw) {
    const merged = {};
    if (!isRecord(raw))
        return merged;
    for (const [from, into] of Object.entries(raw)) {
        if (typeof into === "string")
            merged[from] = into;
    }
    return merged;
}
function parseNextSeq(raw) {
    return typeof raw === "number" && Number.isInteger(raw) && raw > 0 ? raw : 1;
}
function parseDoc(raw) {
    if (!isRecord(raw) || raw["v"] !== 1)
        throw new Error("expected an object with v: 1");
    const topics = raw["topics"];
    if (!isRecord(topics))
        throw new Error("topics is not an object");
    const doc = emptyState().doc;
    for (const [id, topic] of Object.entries(topics))
        doc.topics[id] = parseTopic(id, topic);
    const queues = isRecord(raw["queues"]) ? raw["queues"] : {};
    for (const queue of QUEUES)
        doc.queues[queue] = parseQueue(queues[queue], doc.topics);
    doc.merged = parseMerged(raw["merged"]);
    doc.next_seq = parseNextSeq(raw["next_seq"]);
    return doc;
}
function parseArchive(raw) {
    if (!isRecord(raw) || raw["v"] !== 1 || !isRecord(raw["topics"])) {
        throw new Error("expected an object with v: 1 and topics");
    }
    const archive = { v: 1, topics: {} };
    for (const [id, topic] of Object.entries(raw["topics"])) {
        const parsed = parseTopic(id, topic);
        const archived = { ...parsed, archived_at: stringField(topic, "archived_at") ?? "" };
        archive.topics[id] = archived;
    }
    return archive;
}
function loadFile(file, parse, fallback) {
    let raw;
    try {
        raw = readJsonFile(file);
    }
    catch (error) {
        throw new Error(`${file} 讀不懂：${error.message}`);
    }
    if (raw === null)
        return fallback;
    try {
        return parse(raw);
    }
    catch (error) {
        throw new Error(`${file} 讀不懂：${error.message}`);
    }
}
export function loadTopicState(paths) {
    const empty = emptyState();
    const state = {
        doc: loadFile(paths.topics, parseDoc, empty.doc),
        archive: loadFile(paths.archive, parseArchive, empty.archive),
    };
    // A crash between the two writes of an archive or reopen can leave a topic in
    // both files. The live copy wins: an interrupted archive is simply redone,
    // and an interrupted reopen is already complete.
    for (const id of Object.keys(state.archive.topics)) {
        if (state.doc.topics[id] !== undefined)
            delete state.archive.topics[id];
    }
    return state;
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
