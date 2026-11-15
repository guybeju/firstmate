// Where the board keeps its files. One place, so the service and the client
// can never disagree about a path.
import path from "node:path";

export const DEFAULT_PORT = 47819;

export interface BoardConfig {
  /** The main home. */
  home: string;
  /** The code root whose bin/ scripts the board runs. */
  root: string;
  /** The code root's git commit, read by fm-topic.sh. */
  commit: string;
  port: number;
  /** The home's state directory. */
  state: string;
  /** The home's data directory. */
  data: string;
}

export interface BoardPaths {
  runtimeDir: string;
  socket: string;
  token: string;
  port: string;
  pid: string;
  log: string;
  startupError: string;
  audit: string;
  topics: string;
  archive: string;
  dataDir: string;
  boardDataDir: string;
  events: string;
  summaries: string;
}

export function boardPaths(config: Pick<BoardConfig, "state" | "data">): BoardPaths {
  const runtimeDir = path.join(config.state, "topic-board");
  const boardDataDir = path.join(config.data, "topic-board");
  return {
    runtimeDir,
    socket: path.join(runtimeDir, "board.sock"),
    token: path.join(runtimeDir, "token"),
    port: path.join(runtimeDir, "port"),
    pid: path.join(runtimeDir, "pid"),
    log: path.join(runtimeDir, "service.log"),
    startupError: path.join(runtimeDir, "startup-error"),
    audit: path.join(runtimeDir, "audit.jsonl"),
    topics: path.join(config.data, "topics.json"),
    archive: path.join(config.data, "topics-archive.json"),
    dataDir: config.data,
    boardDataDir,
    events: path.join(boardDataDir, "events.jsonl"),
    summaries: path.join(boardDataDir, "summaries.jsonl"),
  };
}

const CONFIG_FLAGS = ["home", "root", "commit", "port", "state", "data"] as const;

/** Reads leading `--flag value` pairs up to `--`; returns them and the arguments after it. */
function splitFlags(argv: string[]): { values: Map<string, string>; rest: string[] } {
  const values = new Map<string, string>();
  let index = 0;
  while (index < argv.length && argv[index] !== "--") {
    const flag = argv[index] as string;
    const value = argv[index + 1];
    const name = flag.startsWith("--") ? flag.slice(2) : "";
    if (!(CONFIG_FLAGS as readonly string[]).includes(name) || value === undefined) {
      throw new Error(`unexpected argument: ${flag}`);
    }
    values.set(name, value);
    index += 2;
  }
  return { values, rest: argv.slice(index + 1) };
}

/**
 * Reads the `--home --root --commit --port --state --data` flags that
 * fm-topic.sh passes to both programs, and returns the remaining arguments.
 */
export function parseConfigArgs(argv: string[]): { config: BoardConfig; rest: string[] } {
  const { values, rest } = splitFlags(argv);
  const need = (name: string): string => {
    const value = values.get(name);
    if (value === undefined || value === "") throw new Error(`missing --${name}`);
    return value;
  };
  const port = Number(need("port"));
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("--port is not a port number");
  return {
    config: { home: need("home"), root: need("root"), commit: need("commit"), port, state: need("state"), data: need("data") },
    rest,
  };
}
