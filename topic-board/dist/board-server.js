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
import { fileSize, isAlive, isRecord, readCompleteLines, readPidFile, removeStaleTemps, stringField, writeFileAtomic, } from "./files.js";
import * as actions from "./actions.js";
import { commandRunner } from "./commands.js";
import { Journal, MAIN_HOME, Offsets, SUMMARY_KINDS, SUMMARY_MAX, Summaries } from "./journal.js";
import { boardPaths, parseConfigArgs } from "./layout.js";
import { MAX_REQUEST_BYTES } from "./protocol.js";
import { DispatchNotifier } from "./notifier.js";
import { DEFAULT_TIMINGS, Poller } from "./poller.js";
import { loadTopicState, saveTopicState } from "./store.js";
import * as topics from "./topics.js";
import { buildView, placeTask } from "./view.js";
import { DEFAULT_WRITE_TIMINGS, WriteEngine } from "./writes.js";
const PRIVATE_FILE = 0o600;
const HEALTH_PROBE_MS = 3000;
const LOOKUP_WAIT_MS = 10_000;
const NOTIFY_DELAY_MS = 30_000;
const WRITE_HISTORY_MS = 24 * 60 * 60 * 1000;
const TEST_MODE = process.env["FM_TOPIC_BOARD_TEST"] === "1";
// sizeof(sun_path) minus the terminating NUL. Node silently truncates a longer
// path instead of failing, so the length is checked before listening.
const SOCKET_PATH_MAX = os.platform() === "darwin" ? 103 : 107;
function log(message) {
    process.stdout.write(`${new Date().toISOString()} ${process.pid} ${message}\n`);
}
function epochSeconds() {
    return Math.floor(Date.now() / 1000);
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
        service.notifier.observe(service.state, result.state, result.dispatchable);
        service.state = result.state;
        for (const event of result.events) {
            service.journal.appendBoard({ ts: epochSeconds(), home: null, task: null, ...event });
        }
        service.version += 1;
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
        polling: service.poller.active,
        homes: service.poller.snapshots().map((home) => ({ id: home.id, version: home.version })),
        events_bytes: fileSize(service.paths.events),
        summaries_bytes: fileSize(service.paths.summaries),
        audit_bytes: fileSize(service.paths.audit),
    };
}
function resetToken(service) {
    writeFileAtomic(service.paths.token, `${crypto.randomBytes(32).toString("hex")}\n`, PRIVATE_FILE);
    return { ok: true, line: "ok reset-token 已重置，請重新跑 open" };
}
function withTimeout(promise, ms, fallback) {
    return new Promise((resolve) => {
        const timer = setTimeout(() => resolve(fallback), ms);
        void promise.then((value) => {
            clearTimeout(timer);
            resolve(value);
        });
    });
}
/** The home a `--home` argument names, or a refusal when it is not a registered secondmate. */
async function homeArg(service, args) {
    const home = args["home"];
    if (home === undefined)
        return MAIN_HOME;
    if (typeof home !== "string")
        return usage("--home 要是 secondmate id。");
    // A board started just now has never read the main home, so it does not know the secondmates yet.
    if (!service.poller.hasMainReport())
        await withTimeout(service.poller.readNow(MAIN_HOME), LOOKUP_WAIT_MS, false);
    return service.poller.knows(home) && home !== MAIN_HOME
        ? home
        : refused(`--home ${home} 不是已註冊的 secondmate。`);
}
/**
 * The line firstmate puts in front of a chat reminder about `task`. A home that
 * cannot be read gives "議題不明", never "未分類": not knowing is not the same
 * as knowing the task has no topic.
 */
async function reminderPrefix(service, home, task) {
    const place = () => placeTask(service.state, service.poller.snapshots(), home, task);
    let placement = place();
    if (placement.reason === "no-tag") {
        const read = await withTimeout(service.poller.readFresh(home), LOOKUP_WAIT_MS, false);
        if (!read)
            return `議題不明（${task}）：`;
        placement = place();
    }
    if (placement.topic === null)
        return "未分類：";
    const name = service.state.doc.topics[placement.topic]?.name ?? service.state.archive.topics[placement.topic]?.name;
    return `${name ?? placement.topic}：`;
}
function taskArg(args) {
    const task = stringField(args, "task");
    return task !== null && /^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(task) ? task : null;
}
/** The text of a summary, or a refusal when it is empty or too long. */
function summaryText(args) {
    const text = stringField(args, "text")?.trim() ?? "";
    const length = [...text].length;
    return length === 0 || length > SUMMARY_MAX
        ? refused(`摘要要有內容，而且最多 ${SUMMARY_MAX} 個字（這次是 ${length} 個）。`)
        : text;
}
async function summary(service, args) {
    const task = taskArg(args);
    const kind = SUMMARY_KINDS.find((name) => name === args["kind"]);
    if (task === null || kind === undefined)
        return usage("summary 需要 task id 與 ready、report、failed、landed 其中一種。");
    const text = summaryText(args);
    if (typeof text !== "string")
        return text;
    const home = await homeArg(service, args);
    if (typeof home !== "string")
        return home;
    if (service.summaries.add({ ts: epochSeconds(), home, task, kind, text }))
        service.version += 1;
    return { ok: true, line: await reminderPrefix(service, home, task) };
}
async function which(service, args) {
    const task = taskArg(args);
    if (task === null)
        return usage("which 需要 task id。");
    const home = await homeArg(service, args);
    if (typeof home !== "string")
        return home;
    return { ok: true, line: await reminderPrefix(service, home, task) };
}
function writeView(record) {
    return {
        id: record.id,
        kind: record.plan.type,
        home: record.home,
        task: record.task,
        topic: record.topic,
        text: record.text,
        state: record.state,
        error: record.error,
        attempt: record.attempt,
        next_at: record.nextAt,
        created_at: record.createdAt,
    };
}
/** Writes worth showing: everything from the last day, plus anything still unsettled. */
function visibleWrites(service) {
    const settled = ["delivered", "handled_elsewhere", "ignored"];
    const cutoff = Date.now() - WRITE_HISTORY_MS;
    return [...service.writes.records.values()]
        .filter((record) => record.createdAt >= cutoff || !settled.includes(record.state))
        .map(writeView);
}
function actionContext(service) {
    return {
        topics: service.state,
        homes: service.poller.snapshots(),
        secondmates: service.poller.secondmates(),
        writes: service.writes,
    };
}
function boardView(service) {
    return {
        boot_id: service.bootId,
        version: service.version,
        polling: service.poller.active,
        writes: visibleWrites(service),
        ...buildView({
            topics: service.state,
            homes: service.poller.snapshots(),
            events: service.journal.events,
            summaries: service.summaries.all,
            nowMs: Date.now(),
            staleMs: service.timings.staleMs,
        }),
    };
}
/** Test-only: the whole board state, as the page will get it. Counts as a viewer. */
async function dump(service, args) {
    service.poller.touch();
    if (args["refresh"] === true)
        await service.poller.refreshAll();
    return { ok: true, line: "ok", data: boardView(service) };
}
function actionResponse(result) {
    return result.ok ? { ok: true, line: `ok ${result.write.id}`, data: { write_id: result.write.id } } : refused(result.line);
}
/** Test-only: submit a write the way the browser API will. */
async function testWrite(service, args) {
    const context = actionContext(service);
    const field = (name) => stringField(args, name) ?? "";
    switch (args["kind"]) {
        case "message":
            return actionResponse(actions.message(context, field("topic"), field("text"), "socket"));
        case "direct":
            return actionResponse(actions.direct(context, field("home"), field("task"), field("text"), "socket"));
        case "tag":
            return actionResponse(actions.tagAgent(context, field("home"), field("task"), field("topic"), "socket"));
        case "answer": {
            const mode = actions.ANSWER_MODES.find((name) => name === args["mode"]);
            if (mode === undefined)
                return usage("mode 要是 done 或 release。");
            const input = { home: field("home"), task: field("task"), answer: field("answer"), label: field("label"), mode };
            return actionResponse(actions.answer(context, input, "socket"));
        }
        default:
            return usage("不認得的寫入種類。");
    }
}
async function testResend(service, args) {
    const problem = service.writes.resend(stringField(args, "write_id") ?? "", args["confirmed"] === true);
    return problem === null ? { ok: true, line: "ok" } : refused(problem);
}
async function testIgnore(service, args) {
    const problem = service.writes.ignore(stringField(args, "write_id") ?? "");
    return problem === null ? { ok: true, line: "ok" } : refused(problem);
}
const SERVICE_HANDLERS = {
    health: async (service) => ({ ok: true, line: "ok", data: { ...healthData(service) } }),
    status: async (service) => ({ ok: true, line: "ok", data: statusData(service) }),
    stop: async () => ({ ok: true, line: "ok stop 看板服務已停止" }),
    "reset-token": async (service) => resetToken(service),
    summary,
    which,
    ...(TEST_MODE ? { dump, "test-write": testWrite, "test-resend": testResend, "test-ignore": testIgnore } : {}),
};
async function handle(service, request) {
    const serviceHandler = SERVICE_HANDLERS[request.op];
    if (serviceHandler !== undefined)
        return serviceHandler(service, request.args);
    const topicHandler = TOPIC_HANDLERS[request.op];
    if (topicHandler === undefined)
        return usage(`不認得的 op：${request.op}`);
    const result = topicHandler(service, request.args);
    return "usage" in result ? usage(result.usage) : commit(service, result);
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
    service.poller?.stop();
    service.writes?.stop();
    service.notifier?.stop();
    service.ipc?.close();
    service.web.close();
    for (const file of [service.paths.socket, service.paths.pid]) {
        fs.rmSync(file, { force: true });
    }
    process.exit(0);
}
async function respond(service, connection, line) {
    const request = parseRequest(line);
    let response;
    try {
        response = request === null ? usage("要求不是合法的 JSON。") : await handle(service, request);
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
        void respond(service, connection, buffered.slice(0, newline));
    });
}
/** Test runs may shorten the poll timings through FM_TOPIC_BOARD_*_MS variables. */
function pollTimings() {
    if (!TEST_MODE)
        return DEFAULT_TIMINGS;
    const override = (name, fallback) => {
        const value = Number(process.env[`FM_TOPIC_BOARD_${name}_MS`]);
        return Number.isFinite(value) && value > 0 ? value : fallback;
    };
    return {
        ...DEFAULT_TIMINGS,
        localMs: override("LOCAL", DEFAULT_TIMINGS.localMs),
        remoteMs: override("REMOTE", DEFAULT_TIMINGS.remoteMs),
        idleMs: override("IDLE", DEFAULT_TIMINGS.idleMs),
        staleMs: override("STALE", DEFAULT_TIMINGS.staleMs),
    };
}
/** Test runs may shorten the write timings through FM_TOPIC_BOARD_RETRY_MS and _RESUME_MS. */
function writeTimings() {
    if (!TEST_MODE)
        return DEFAULT_WRITE_TIMINGS;
    const delays = (process.env["FM_TOPIC_BOARD_RETRY_MS"] ?? "").split(",").map(Number);
    const resume = Number(process.env["FM_TOPIC_BOARD_RESUME_MS"]);
    return {
        ...DEFAULT_WRITE_TIMINGS,
        ...(delays.every((delay) => Number.isFinite(delay) && delay > 0) ? { retryDelaysMs: delays } : {}),
        ...(Number.isFinite(resume) && resume > 0 ? { resumeWindowMs: resume } : {}),
    };
}
function notifyDelay() {
    const override = Number(process.env["FM_TOPIC_BOARD_NOTIFY_MS"]);
    return TEST_MODE && Number.isFinite(override) && override > 0 ? override : NOTIFY_DELAY_MS;
}
/** Tells firstmate which topics just became dispatchable, as one note. */
function notifyDispatchable(service, topicIds) {
    const names = topicIds
        .filter((id) => service.state.doc.topics[id] !== undefined)
        .map((id) => `「${service.state.doc.topics[id]?.name ?? id}」`);
    if (names.length === 0)
        return;
    service.writes.submit({
        channel: "auto",
        home: MAIN_HOME,
        task: null,
        topic: topicIds[0] ?? null,
        text: `議題${names.join("、")}已可派工，請跑 order 重新評估`,
        plan: {
            type: "note",
            requestId: `tb-dispatch-${crypto.randomBytes(8).toString("hex")}`,
            body: `議題${names.join("、")}已可派工，請跑 order 重新評估`,
        },
    });
}
/** Records a delivered answer or tag as a system record and re-reads the home it changed. */
function recordDelivery(service, record) {
    const kinds = { answer: "hold.answered", tag: "agent.tagged" };
    const kind = kinds[record.plan.type];
    if (kind === undefined)
        return;
    const text = record.plan.type === "answer" ? `在看板回答 ${record.home}/${record.task ?? ""}：${record.text}` : `${record.home}/${record.task ?? ""} ${record.text}`;
    service.journal.appendBoard({ ts: epochSeconds(), kind, topic: record.topic, home: record.home, task: record.task, text });
    service.version += 1;
    void service.poller.readNow(record.home);
}
/** Loads everything the board keeps on disk and returns the running service's state. */
function loadService(boot) {
    const { paths } = boot;
    fs.mkdirSync(paths.boardDataDir, { recursive: true });
    for (const dir of [paths.runtimeDir, paths.dataDir, paths.boardDataDir]) {
        for (const name of removeStaleTemps(dir))
            log(`removed stale temp file ${name} in ${dir}`);
    }
    const timings = pollTimings();
    const journal = new Journal(paths.events);
    const run = commandRunner(boot.config);
    const bump = () => {
        service.version += 1;
    };
    const service = {
        ...boot,
        state: loadTopicState(paths),
        journal,
        summaries: new Summaries(paths.summaries),
        timings,
        version: 1,
        ipc: null,
        poller: new Poller(run, journal, new Offsets(paths), timings, bump),
        notifier: new DispatchNotifier(notifyDelay(), (ids) => notifyDispatchable(service, ids)),
        writes: new WriteEngine(paths.audit, {
            run,
            secondmates: () => service.poller.secondmates(),
            readTags: async (home, task) => (await service.poller.readFresh(home))
                ? (service.poller.snapshots().find((entry) => entry.id === home)?.report?.topics[task] ?? "")
                : null,
            prepare: async () => {
                await service.poller.readNow(MAIN_HOME);
            },
            onChange: bump,
            onDelivered: (record) => recordDelivery(service, record),
        }, writeTimings()),
    };
    void service.writes.resumeUnfinished();
    return service;
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
function becomeTheBoard(boot) {
    const { paths, config } = boot;
    // Claim the pid file before the slow part of startup: a second board started
    // meanwhile reads it to learn the port is held by a board, not a stranger.
    writeFileAtomic(paths.pid, `${process.pid}\n`, PRIVATE_FILE);
    let service;
    try {
        service = loadService(boot);
    }
    catch (error) {
        failStartup(paths, error.message, "修好或移開那個檔之後再試");
    }
    if (!fs.existsSync(paths.token)) {
        writeFileAtomic(paths.token, `${crypto.randomBytes(32).toString("hex")}\n`, PRIVATE_FILE);
    }
    writeFileAtomic(paths.port, `${config.port}\n`, PRIVATE_FILE);
    process.removeAllListeners("SIGTERM").on("SIGTERM", () => shutdown(service));
    process.removeAllListeners("SIGINT").on("SIGINT", () => shutdown(service));
    bindSocket(service);
}
/** The port is taken: exit quietly if a board already answers, else report who holds it. */
function yieldOrFail(boot) {
    const { paths, config } = boot;
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
    const boot = { config, paths, bootId: crypto.randomBytes(8).toString("hex"), startedAt: now(), web };
    web.once("error", (error) => {
        if (error.code === "EADDRINUSE")
            yieldOrFail(boot);
        else
            failStartup(paths, `埠 ${config.port} 綁不起來（${error.message}）`, "在 config/topic-board-port 寫另一個埠號");
    });
    web.listen(config.port, "127.0.0.1", () => becomeTheBoard(boot));
    process.on("SIGTERM", () => shutdown(boot));
    process.on("SIGINT", () => shutdown(boot));
}
main();
