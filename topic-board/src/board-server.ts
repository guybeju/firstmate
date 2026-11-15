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
import {
  fileSize,
  isAlive,
  isRecord,
  readCompleteLines,
  readPidFile,
  removeStaleTemps,
  stringField,
  writeFileAtomic,
} from "./files.js";
import { commandRunner } from "./commands.js";
import { Journal, MAIN_HOME, Offsets, SUMMARY_KINDS, SUMMARY_MAX, Summaries } from "./journal.js";
import { boardPaths, parseConfigArgs } from "./layout.js";
import type { BoardConfig, BoardPaths } from "./layout.js";
import { MAX_REQUEST_BYTES } from "./protocol.js";
import type { BoardRequest, BoardResponse, HealthData } from "./protocol.js";
import { DEFAULT_TIMINGS, Poller } from "./poller.js";
import type { PollTimings } from "./poller.js";
import { loadTopicState, saveTopicState } from "./store.js";
import * as topics from "./topics.js";
import type { MovePosition, Queue, TopicResult, TopicState } from "./topics.js";
import { buildView, placeTask } from "./view.js";

const PRIVATE_FILE = 0o600;
const HEALTH_PROBE_MS = 3000;
const LOOKUP_WAIT_MS = 10_000;
const TEST_MODE = process.env["FM_TOPIC_BOARD_TEST"] === "1";
// sizeof(sun_path) minus the terminating NUL. Node silently truncates a longer
// path instead of failing, so the length is checked before listening.
const SOCKET_PATH_MAX = os.platform() === "darwin" ? 103 : 107;

/** What exists as soon as the process starts, before it has won the port. */
interface Boot {
  config: BoardConfig;
  paths: BoardPaths;
  bootId: string;
  startedAt: string;
  web: http.Server;
}

interface Service extends Boot {
  state: TopicState;
  journal: Journal;
  summaries: Summaries;
  poller: Poller;
  timings: PollTimings;
  /** Bumped whenever anything a viewer could see changes. */
  version: number;
  ipc: net.Server | null;
}

function log(message: string): void {
  process.stdout.write(`${new Date().toISOString()} ${process.pid} ${message}\n`);
}

function epochSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function now(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Records why startup failed where the client can read it, then exits. */
function failStartup(paths: BoardPaths, reason: string, fix: string): never {
  log(`startup failed: ${reason}`);
  if (readPidFile(paths.pid) === process.pid) fs.rmSync(paths.pid, { force: true });
  try {
    writeFileAtomic(paths.startupError, `${JSON.stringify({ reason, fix })}\n`, PRIVATE_FILE);
  } catch (error) {
    log(`could not record the startup failure: ${(error as Error).message}`);
  }
  process.exit(1);
}

function refused(line: string): BoardResponse {
  return { ok: false, code: "refused", line };
}

function usage(line: string): BoardResponse {
  return { ok: false, code: "usage", line };
}

function optionalQueue(args: Record<string, unknown>): Queue | undefined | null {
  const value = args["queue"];
  if (value === undefined) return undefined;
  return topics.isQueue(value) ? value : null;
}

/** Persists a topic change and turns it into the response for the caller. */
function commit(service: Service, result: TopicResult): BoardResponse {
  if (!result.ok) return refused(result.line);
  if (result.changed) {
    saveTopicState(service.paths, service.state, result.state);
    service.state = result.state;
    for (const event of result.events) {
      service.journal.appendBoard({ ts: epochSeconds(), home: null, task: null, ...event });
    }
    service.version += 1;
  }
  return { ok: true, line: result.line };
}

/** A handler either rejects malformed arguments or returns the topic change to persist. */
type TopicHandler = (service: Service, args: Record<string, unknown>) => TopicResult | { usage: string };

function movePosition(args: Record<string, unknown>): MovePosition | null {
  const before = args["before"];
  if (args["first"] === true) return before === undefined ? { first: true } : null;
  if (before === undefined) return undefined;
  return typeof before === "string" ? { before } : null;
}

const TOPIC_HANDLERS: Record<string, TopicHandler> = {
  propose: (service, args) => {
    const name = stringField(args, "name");
    const goal = stringField(args, "goal");
    const queue = optionalQueue(args);
    const id = args["id"];
    if (name === null || goal === null || queue === null) return { usage: "propose 需要名稱與 --goal。" };
    if (id !== undefined && typeof id !== "string") return { usage: "--id 要是字串。" };
    return topics.propose(
      service.state,
      { name, goal, by: "firstmate", ...(id === undefined ? {} : { id }), ...(queue === undefined ? {} : { queue }) },
      now(),
    );
  },
  confirm: (service, args) => {
    const id = stringField(args, "id");
    const queue = optionalQueue(args);
    if (id === null || queue === null) return { usage: "confirm 需要議題 id。" };
    return topics.confirm(service.state, id, queue);
  },
  merge: (service, args) => {
    const from = stringField(args, "from");
    const into = stringField(args, "into");
    if (from === null || into === null) return { usage: "merge 需要兩個議題 id。" };
    return topics.merge(service.state, from, into);
  },
  "close-propose": (service, args) => {
    const id = stringField(args, "id");
    const reason = stringField(args, "reason");
    if (id === null || reason === null) return { usage: "close-propose 需要議題 id 與 --reason。" };
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
    if (id === null || value === null) return { usage: "rename 需要議題 id 與名稱。" };
    return topics.rename(service.state, id, value);
  },
  goal: (service, args) => {
    const id = stringField(args, "id");
    const value = stringField(args, "value");
    if (id === null || value === null) return { usage: "goal 需要議題 id 與一行目標。" };
    return topics.setGoal(service.state, id, value);
  },
  archive: (service, args) => {
    const id = stringField(args, "id");
    if (id === null) return { usage: "archive 需要議題 id。" };
    return topics.archive(service.state, id, now());
  },
  reopen: (service, args) => {
    const id = stringField(args, "id");
    const queue = optionalQueue(args);
    if (id === null || queue === null) return { usage: "reopen 需要議題 id。" };
    return topics.reopen(service.state, id, queue);
  },
};

function healthData(service: Service): HealthData {
  return {
    pid: process.pid,
    port: service.config.port,
    code_commit: service.config.commit,
    boot_id: service.bootId,
    started_at: service.startedAt,
  };
}

function statusData(service: Service): Record<string, unknown> {
  return {
    ...healthData(service),
    polling: service.poller.active,
    homes: service.poller.snapshots().map((home) => ({ id: home.id, version: home.version })),
    events_bytes: fileSize(service.paths.events),
    summaries_bytes: fileSize(service.paths.summaries),
    audit_bytes: fileSize(service.paths.audit),
  };
}

function resetToken(service: Service): BoardResponse {
  writeFileAtomic(service.paths.token, `${crypto.randomBytes(32).toString("hex")}\n`, PRIVATE_FILE);
  return { ok: true, line: "ok reset-token 已重置，請重新跑 open" };
}

function withTimeout<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(fallback), ms);
    void promise.then((value) => {
      clearTimeout(timer);
      resolve(value);
    });
  });
}

/** The home a `--home` argument names, or a refusal when it is not a registered secondmate. */
async function homeArg(service: Service, args: Record<string, unknown>): Promise<string | BoardResponse> {
  const home = args["home"];
  if (home === undefined) return MAIN_HOME;
  if (typeof home !== "string") return usage("--home 要是 secondmate id。");
  // A board started just now has never read the main home, so it does not know the secondmates yet.
  if (!service.poller.hasMainReport()) await withTimeout(service.poller.readNow(MAIN_HOME), LOOKUP_WAIT_MS, false);
  return service.poller.knows(home) && home !== MAIN_HOME
    ? home
    : refused(`--home ${home} 不是已註冊的 secondmate。`);
}

/**
 * The line firstmate puts in front of a chat reminder about `task`. A home that
 * cannot be read gives "議題不明", never "未分類": not knowing is not the same
 * as knowing the task has no topic.
 */
async function reminderPrefix(service: Service, home: string, task: string): Promise<string> {
  const place = (): ReturnType<typeof placeTask> => placeTask(service.state, service.poller.snapshots(), home, task);
  let placement = place();
  if (placement.reason === "no-tag") {
    const read = await withTimeout(service.poller.readFresh(home), LOOKUP_WAIT_MS, false);
    if (!read) return `議題不明（${task}）：`;
    placement = place();
  }
  if (placement.topic === null) return "未分類：";
  const name = service.state.doc.topics[placement.topic]?.name ?? service.state.archive.topics[placement.topic]?.name;
  return `${name ?? placement.topic}：`;
}

function taskArg(args: Record<string, unknown>): string | null {
  const task = stringField(args, "task");
  return task !== null && /^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(task) ? task : null;
}

/** The text of a summary, or a refusal when it is empty or too long. */
function summaryText(args: Record<string, unknown>): string | BoardResponse {
  const text = stringField(args, "text")?.trim() ?? "";
  const length = [...text].length;
  return length === 0 || length > SUMMARY_MAX
    ? refused(`摘要要有內容，而且最多 ${SUMMARY_MAX} 個字（這次是 ${length} 個）。`)
    : text;
}

async function summary(service: Service, args: Record<string, unknown>): Promise<BoardResponse> {
  const task = taskArg(args);
  const kind = SUMMARY_KINDS.find((name) => name === args["kind"]);
  if (task === null || kind === undefined) return usage("summary 需要 task id 與 ready、report、failed、landed 其中一種。");
  const text = summaryText(args);
  if (typeof text !== "string") return text;
  const home = await homeArg(service, args);
  if (typeof home !== "string") return home;
  if (service.summaries.add({ ts: epochSeconds(), home, task, kind, text })) service.version += 1;
  return { ok: true, line: await reminderPrefix(service, home, task) };
}

async function which(service: Service, args: Record<string, unknown>): Promise<BoardResponse> {
  const task = taskArg(args);
  if (task === null) return usage("which 需要 task id。");
  const home = await homeArg(service, args);
  if (typeof home !== "string") return home;
  return { ok: true, line: await reminderPrefix(service, home, task) };
}

function boardView(service: Service): Record<string, unknown> {
  return {
    boot_id: service.bootId,
    version: service.version,
    polling: service.poller.active,
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
async function dump(service: Service, args: Record<string, unknown>): Promise<BoardResponse> {
  service.poller.touch();
  if (args["refresh"] === true) await service.poller.refreshAll();
  return { ok: true, line: "ok", data: boardView(service) };
}

type AsyncHandler = (service: Service, args: Record<string, unknown>) => Promise<BoardResponse>;

const SERVICE_HANDLERS: Record<string, AsyncHandler> = {
  health: async (service) => ({ ok: true, line: "ok", data: { ...healthData(service) } }),
  status: async (service) => ({ ok: true, line: "ok", data: statusData(service) }),
  stop: async () => ({ ok: true, line: "ok stop 看板服務已停止" }),
  "reset-token": async (service) => resetToken(service),
  summary,
  which,
  ...(TEST_MODE ? { dump } : {}),
};

async function handle(service: Service, request: BoardRequest): Promise<BoardResponse> {
  const serviceHandler = SERVICE_HANDLERS[request.op];
  if (serviceHandler !== undefined) return serviceHandler(service, request.args);
  const topicHandler = TOPIC_HANDLERS[request.op];
  if (topicHandler === undefined) return usage(`不認得的 op：${request.op}`);
  const result = topicHandler(service, request.args);
  return "usage" in result ? usage(result.usage) : commit(service, result);
}

function parseRequest(line: string): BoardRequest | null {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(raw) || raw["v"] !== 1) return null;
  const { op, args } = raw;
  if (typeof op !== "string" || !isRecord(args)) return null;
  return { v: 1, op, args };
}

function shutdown(service: Boot & { ipc?: net.Server | null; poller?: Poller }): void {
  log("stopping");
  service.poller?.stop();
  service.ipc?.close();
  service.web.close();
  for (const file of [service.paths.socket, service.paths.pid]) {
    fs.rmSync(file, { force: true });
  }
  process.exit(0);
}

async function respond(service: Service, connection: net.Socket, line: string): Promise<void> {
  const request = parseRequest(line);
  let response: BoardResponse;
  try {
    response = request === null ? usage("要求不是合法的 JSON。") : await handle(service, request);
  } catch (error) {
    log(`request failed: ${(error as Error).stack ?? String(error)}`);
    response = refused(`看板服務處理這個要求時出錯：${(error as Error).message}`);
  }
  connection.end(`${JSON.stringify(response)}\n`, () => {
    if (request?.op === "stop" && response.ok) shutdown(service);
  });
}

function serveConnection(service: Service, connection: net.Socket): void {
  let buffered = "";
  let answered = false;
  connection.setEncoding("utf8");
  connection.on("error", (error) => log(`connection error: ${error.message}`));
  connection.on("data", (chunk: string) => {
    if (answered) return;
    buffered += chunk;
    const newline = buffered.indexOf("\n");
    if (newline === -1 && Buffer.byteLength(buffered) <= MAX_REQUEST_BYTES) return;
    answered = true;
    if (newline === -1) {
      connection.end(`${JSON.stringify(usage("要求太大。"))}\n`);
      return;
    }
    void respond(service, connection, buffered.slice(0, newline));
  });
}

/** Test runs may shorten the poll timings through FM_TOPIC_BOARD_*_MS variables. */
function pollTimings(): PollTimings {
  if (!TEST_MODE) return DEFAULT_TIMINGS;
  const override = (name: string, fallback: number): number => {
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

/** Loads everything the board keeps on disk and returns the running service's state. */
function loadService(boot: Boot): Service {
  const { paths } = boot;
  fs.mkdirSync(paths.boardDataDir, { recursive: true });
  for (const dir of [paths.runtimeDir, paths.dataDir, paths.boardDataDir]) {
    for (const name of removeStaleTemps(dir)) log(`removed stale temp file ${name} in ${dir}`);
  }
  readCompleteLines(paths.audit);
  const timings = pollTimings();
  const journal = new Journal(paths.events);
  const service: Service = {
    ...boot,
    state: loadTopicState(paths),
    journal,
    summaries: new Summaries(paths.summaries),
    timings,
    version: 1,
    ipc: null,
    poller: new Poller(commandRunner(boot.config), journal, new Offsets(paths), timings, () => {
      service.version += 1;
    }),
  };
  return service;
}

function bindSocket(service: Service): void {
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

function becomeTheBoard(boot: Boot): void {
  const { paths, config } = boot;
  // Claim the pid file before the slow part of startup: a second board started
  // meanwhile reads it to learn the port is held by a board, not a stranger.
  writeFileAtomic(paths.pid, `${process.pid}\n`, PRIVATE_FILE);
  let service: Service;
  try {
    service = loadService(boot);
  } catch (error) {
    failStartup(paths, (error as Error).message, "修好或移開那個檔之後再試");
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
function yieldOrFail(boot: Boot): void {
  const { paths, config } = boot;
  const holderIsNotBoard = (): never =>
    failStartup(paths, `埠 ${config.port} 被別的程式佔用`, "在 config/topic-board-port 寫另一個埠號");
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

function main(): void {
  const { config } = parseConfigArgs(process.argv.slice(2));
  const paths = boardPaths(config);
  const socketBytes = Buffer.byteLength(paths.socket);
  if (socketBytes > SOCKET_PATH_MAX) {
    failStartup(
      paths,
      `socket 路徑太長（${socketBytes} 位元組，上限 ${SOCKET_PATH_MAX}）`,
      "home 的路徑太深，請把 home 搬到較短的路徑",
    );
  }
  const web = http.createServer((_request, response) => {
    response.writeHead(404, { "Content-Type": "text/plain" });
    response.end("not found\n");
  });
  const boot: Boot = { config, paths, bootId: crypto.randomBytes(8).toString("hex"), startedAt: now(), web };
  web.once("error", (error: NodeJS.ErrnoException) => {
    if (error.code === "EADDRINUSE") yieldOrFail(boot);
    else failStartup(paths, `埠 ${config.port} 綁不起來（${error.message}）`, "在 config/topic-board-port 寫另一個埠號");
  });
  web.listen(config.port, "127.0.0.1", () => becomeTheBoard(boot));
  process.on("SIGTERM", () => shutdown(boot));
  process.on("SIGINT", () => shutdown(boot));
}

main();
