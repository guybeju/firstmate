// The topic board service. It runs in the main home, is the only writer of the
// topic files, and answers fm-topic.sh over a Unix socket.
//
// Started by board-client.js with the flags parseConfigArgs reads. Binding the
// TCP port decides which process is the board: only the process that holds the
// port may clear a stale socket file and bind the socket.
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import { appendLine, fileSize, isAlive, isRecord, readCompleteLines, readPidFile, removeStaleTemps, stringField, writeFileAtomic, } from "./files.js";
import { boardPaths, parseConfigArgs } from "./layout.js";
import { MAX_REQUEST_BYTES } from "./protocol.js";
import { loadTopicState, saveTopicState } from "./store.js";
import * as topics from "./topics.js";
const PRIVATE_FILE = 0o600;
const SHARED_FILE = 0o644;
const HEALTH_PROBE_MS = 3000;
// sizeof(sun_path) minus the terminating NUL. Node silently truncates a longer
// path instead of failing, so the length is checked before listening.
const SOCKET_PATH_MAX = os.platform() === "darwin" ? 103 : 107;
function log(message) {
    process.stdout.write(`${new Date().toISOString()} ${process.pid} ${message}\n`);
}
function now() {
    return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}
/** Records why startup failed where the client can read it, then exits. */
function failStartup(paths, reason, fix) {
    log(`startup failed: ${reason}`);
    if (readPidFile(paths.pid) === process.pid)
        fs.rmSync(paths.pid, { force: true });
    try {
        writeFileAtomic(paths.startupError, `${JSON.stringify({ reason, fix })}\n`, PRIVATE_FILE);
    }
    catch (error) {
        log(`could not record the startup failure: ${error.message}`);
    }
    process.exit(1);
}
function refused(line) {
    return { ok: false, code: "refused", line };
}
function usage(line) {
    return { ok: false, code: "usage", line };
}
function optionalQueue(args) {
    const value = args["queue"];
    if (value === undefined)
        return undefined;
    return topics.isQueue(value) ? value : null;
}
/** Persists a topic change and turns it into the response for the caller. */
function commit(service, result) {
    if (!result.ok)
        return refused(result.line);
    if (result.changed) {
        saveTopicState(service.paths, service.state, result.state);
        service.state = result.state;
        for (const event of result.events) {
            appendLine(service.paths.events, JSON.stringify({ src: "board", ts: now(), ...event }), SHARED_FILE);
        }
    }
    return { ok: true, line: result.line };
}
function movePosition(args) {
    const before = args["before"];
    if (args["first"] === true)
        return before === undefined ? { first: true } : null;
    if (before === undefined)
        return undefined;
    return typeof before === "string" ? { before } : null;
}
const TOPIC_HANDLERS = {
    propose: (service, args) => {
        const name = stringField(args, "name");
        const goal = stringField(args, "goal");
        const queue = optionalQueue(args);
        const id = args["id"];
        if (name === null || goal === null || queue === null)
            return { usage: "propose 需要名稱與 --goal。" };
        if (id !== undefined && typeof id !== "string")
            return { usage: "--id 要是字串。" };
        return topics.propose(service.state, { name, goal, by: "firstmate", ...(id === undefined ? {} : { id }), ...(queue === undefined ? {} : { queue }) }, now());
    },
    confirm: (service, args) => {
        const id = stringField(args, "id");
        const queue = optionalQueue(args);
        if (id === null || queue === null)
            return { usage: "confirm 需要議題 id。" };
        return topics.confirm(service.state, id, queue);
    },
    merge: (service, args) => {
        const from = stringField(args, "from");
        const into = stringField(args, "into");
        if (from === null || into === null)
            return { usage: "merge 需要兩個議題 id。" };
        return topics.merge(service.state, from, into);
    },
    "close-propose": (service, args) => {
        const id = stringField(args, "id");
        const reason = stringField(args, "reason");
        if (id === null || reason === null)
            return { usage: "close-propose 需要議題 id 與 --reason。" };
        return topics.closePropose(service.state, id, reason, now());
    },
    move: (service, args) => {
        const id = stringField(args, "id");
        const queue = optionalQueue(args);
        const position = movePosition(args);
        if (id === null || queue === null || queue === undefined || position === null) {
            return { usage: "move 需要議題 id 與佇列（high、normal、later）。" };
        }
        return topics.move(service.state, id, queue, position);
    },
    rename: (service, args) => {
        const id = stringField(args, "id");
        const value = stringField(args, "value");
        if (id === null || value === null)
            return { usage: "rename 需要議題 id 與名稱。" };
        return topics.rename(service.state, id, value);
    },
    goal: (service, args) => {
        const id = stringField(args, "id");
        const value = stringField(args, "value");
        if (id === null || value === null)
            return { usage: "goal 需要議題 id 與一行目標。" };
        return topics.setGoal(service.state, id, value);
    },
    archive: (service, args) => {
        const id = stringField(args, "id");
        if (id === null)
            return { usage: "archive 需要議題 id。" };
        return topics.archive(service.state, id, now());
    },
    reopen: (service, args) => {
        const id = stringField(args, "id");
        const queue = optionalQueue(args);
        if (id === null || queue === null)
            return { usage: "reopen 需要議題 id。" };
        return topics.reopen(service.state, id, queue);
    },
};
function healthData(service) {
    return {
        pid: process.pid,
        port: service.config.port,
        code_commit: service.config.commit,
        boot_id: service.bootId,
        started_at: service.startedAt,
    };
}
function statusData(service) {
    return {
        ...healthData(service),
        polling: false,
        events_bytes: fileSize(service.paths.events),
        summaries_bytes: fileSize(service.paths.summaries),
        audit_bytes: fileSize(service.paths.audit),
    };
}
function resetToken(service) {
    writeFileAtomic(service.paths.token, `${crypto.randomBytes(32).toString("hex")}\n`, PRIVATE_FILE);
    return { ok: true, line: "ok reset-token 已重置，請重新跑 open" };
}
function handle(service, request) {
    switch (request.op) {
        case "health":
            return { ok: true, line: "ok", data: { ...healthData(service) } };
        case "status":
            return { ok: true, line: "ok", data: statusData(service) };
        case "stop":
            return { ok: true, line: "ok stop 看板服務已停止" };
        case "reset-token":
            return resetToken(service);
        default: {
            const handler = TOPIC_HANDLERS[request.op];
            if (handler === undefined)
                return usage(`不認得的 op：${request.op}`);
            const result = handler(service, request.args);
            return "usage" in result ? usage(result.usage) : commit(service, result);
        }
    }
}
function parseRequest(line) {
    let raw;
    try {
        raw = JSON.parse(line);
    }
    catch {
        return null;
    }
    if (!isRecord(raw) || raw["v"] !== 1)
        return null;
    const { op, args } = raw;
    if (typeof op !== "string" || !isRecord(args))
        return null;
    return { v: 1, op, args };
}
function shutdown(service) {
    log("stopping");
    service.ipc?.close();
    service.web.close();
    for (const file of [service.paths.socket, service.paths.pid]) {
        fs.rmSync(file, { force: true });
    }
    process.exit(0);
}
function respond(service, connection, line) {
    const request = parseRequest(line);
    let response;
    try {
        response = request === null ? usage("要求不是合法的 JSON。") : handle(service, request);
    }
    catch (error) {
        log(`request failed: ${error.stack ?? String(error)}`);
        response = refused(`看板服務處理這個要求時出錯：${error.message}`);
    }
    connection.end(`${JSON.stringify(response)}\n`, () => {
        if (request?.op === "stop" && response.ok)
            shutdown(service);
    });
}
function serveConnection(service, connection) {
    let buffered = "";
    let answered = false;
    connection.setEncoding("utf8");
    connection.on("error", (error) => log(`connection error: ${error.message}`));
    connection.on("data", (chunk) => {
        if (answered)
            return;
        buffered += chunk;
        const newline = buffered.indexOf("\n");
        if (newline === -1 && Buffer.byteLength(buffered) <= MAX_REQUEST_BYTES)
            return;
        answered = true;
        if (newline === -1) {
            connection.end(`${JSON.stringify(usage("要求太大。"))}\n`);
            return;
        }
        respond(service, connection, buffered.slice(0, newline));
    });
}
function loadData(service) {
    const { paths } = service;
    fs.mkdirSync(paths.boardDataDir, { recursive: true });
    for (const dir of [paths.runtimeDir, paths.dataDir, paths.boardDataDir]) {
        for (const name of removeStaleTemps(dir))
            log(`removed stale temp file ${name} in ${dir}`);
    }
    service.state = loadTopicState(paths);
    for (const file of [paths.events, paths.summaries, paths.audit])
        readCompleteLines(file);
}
function bindSocket(service) {
    const { paths } = service;
    fs.rmSync(paths.socket, { force: true });
    const ipc = net.createServer((connection) => serveConnection(service, connection));
    ipc.on("error", (error) => failStartup(paths, `socket 綁不起來（${error.message}）`, "檢查 state/topic-board 的權限"));
    const previousMask = process.umask(0o177);
    ipc.listen(paths.socket, () => {
        process.umask(previousMask);
        service.ipc = ipc;
        fs.rmSync(paths.startupError, { force: true });
        log(`ready on port ${service.config.port}, commit ${service.config.commit}`);
    });
}
function becomeTheBoard(service) {
    const { paths, config } = service;
    // Claim the pid file before the slow part of startup: a second board started
    // meanwhile reads it to learn the port is held by a board, not a stranger.
    writeFileAtomic(paths.pid, `${process.pid}\n`, PRIVATE_FILE);
    try {
        loadData(service);
    }
    catch (error) {
        failStartup(paths, error.message, "修好或移開那個檔之後再試");
    }
    if (!fs.existsSync(paths.token)) {
        writeFileAtomic(paths.token, `${crypto.randomBytes(32).toString("hex")}\n`, PRIVATE_FILE);
    }
    writeFileAtomic(paths.port, `${config.port}\n`, PRIVATE_FILE);
    bindSocket(service);
}
/** The port is taken: exit quietly if a board already answers, else report who holds it. */
function yieldOrFail(service) {
    const { paths, config } = service;
    const holderIsNotBoard = () => failStartup(paths, `埠 ${config.port} 被別的程式佔用`, "在 config/topic-board-port 寫另一個埠號");
    const holder = readPidFile(paths.pid);
    if (holder !== null && holder !== process.pid && isAlive(holder)) {
        log(`board ${holder} already holds the port; exiting`);
        process.exit(0);
    }
    const probe = net.connect(paths.socket);
    const timer = setTimeout(holderIsNotBoard, HEALTH_PROBE_MS);
    probe.on("connect", () => probe.write(`${JSON.stringify({ v: 1, op: "health", args: {} })}\n`));
    probe.on("data", () => {
        clearTimeout(timer);
        log("another board already holds the port; exiting");
        process.exit(0);
    });
    probe.on("error", () => {
        clearTimeout(timer);
        holderIsNotBoard();
    });
}
function main() {
    const { config } = parseConfigArgs(process.argv.slice(2));
    const paths = boardPaths(config);
    const socketBytes = Buffer.byteLength(paths.socket);
    if (socketBytes > SOCKET_PATH_MAX) {
        failStartup(paths, `socket 路徑太長（${socketBytes} 位元組，上限 ${SOCKET_PATH_MAX}）`, "home 的路徑太深，請把 home 搬到較短的路徑");
    }
    const web = http.createServer((_request, response) => {
        response.writeHead(404, { "Content-Type": "text/plain" });
        response.end("not found\n");
    });
    const service = {
        config,
        paths,
        bootId: crypto.randomBytes(8).toString("hex"),
        startedAt: now(),
        state: topics.emptyState(),
        web,
        ipc: null,
    };
    web.once("error", (error) => {
        if (error.code === "EADDRINUSE")
            yieldOrFail(service);
        else
            failStartup(paths, `埠 ${config.port} 綁不起來（${error.message}）`, "在 config/topic-board-port 寫另一個埠號");
    });
    web.listen(config.port, "127.0.0.1", () => becomeTheBoard(service));
    process.on("SIGTERM", () => shutdown(service));
    process.on("SIGINT", () => shutdown(service));
}
main();
