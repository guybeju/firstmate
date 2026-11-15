// Reads every home on a schedule while someone is looking at the board, and on
// demand otherwise. It is the only caller of the read commands.
import type { AllowedCommand, CommandRunner, Secondmate } from "./commands.js";
import type { Journal, Offsets } from "./journal.js";
import { MAIN_HOME } from "./journal.js";
import { parseReport } from "./report.js";
import type { HomeReport } from "./report.js";
import type { HomeSnapshot } from "./view.js";

export interface PollTimings {
  localMs: number;
  remoteMs: number;
  /** Polling stops this long after the last viewer asked for the board. */
  idleMs: number;
  staleMs: number;
  localTimeoutMs: number;
  remoteTimeoutMs: number;
}

export const DEFAULT_TIMINGS: PollTimings = {
  localMs: 10_000,
  remoteMs: 60_000,
  idleMs: 120_000,
  staleMs: 180_000,
  localTimeoutMs: 60_000,
  remoteTimeoutMs: 400_000,
};

const TICK_MS = 250;
const MAX_CATCH_UP_READS = 50;
const ERROR_MAX = 400;
// fm-on.sh's refusals when the remote code root has no such tracked script.
const NOT_ON_FORK = [
  "command is not tracked by the configured remote root",
  "command is not a genuine executable in the configured remote root",
];

interface HomeState extends HomeSnapshot {
  home: string;
  reading: Promise<boolean> | null;
  dueAt: number;
}

function mainHome(): HomeState {
  return {
    id: MAIN_HOME,
    remote: false,
    home: "",
    report: null,
    lastOkAt: null,
    error: null,
    version: "unknown",
    reading: null,
    dueAt: 0,
  };
}

export class Poller {
  private readonly homes = new Map<string, HomeState>([[MAIN_HOME, mainHome()]]);
  private lastViewerAt = 0;
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly run: CommandRunner,
    private readonly journal: Journal,
    private readonly offsets: Offsets,
    private readonly timings: PollTimings,
    private readonly onChange: () => void,
  ) {}

  /** True while a viewer asked for the board recently enough to keep polling. */
  get active(): boolean {
    return Date.now() - this.lastViewerAt < this.timings.idleMs;
  }

  /** Records that someone is looking, which starts or continues scheduled polling. */
  touch(): void {
    this.lastViewerAt = Date.now();
    this.timer ??= setInterval(() => this.tick(), TICK_MS);
  }

  stop(): void {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }

  snapshots(): HomeSnapshot[] {
    return [...this.homes.values()].map(({ id, remote, report, lastOkAt, error, version }) => ({
      id,
      remote,
      report,
      lastOkAt,
      error,
      version,
    }));
  }

  secondmates(): Secondmate[] {
    return [...this.homes.values()]
      .filter((home) => home.id !== MAIN_HOME)
      .map((home) => ({ id: home.id, remote: home.remote, home: home.home }));
  }

  hasMainReport(): boolean {
    return this.homes.get(MAIN_HOME)?.report != null;
  }

  knows(home: string): boolean {
    return this.homes.has(home);
  }

  /** Reads one home now (joining a read already in flight); resolves to whether it succeeded. */
  readNow(id: string): Promise<boolean> {
    const home = this.homes.get(id);
    if (home === undefined) return Promise.resolve(false);
    home.reading ??= this.readHome(home).finally(() => {
      home.reading = null;
      home.dueAt = Date.now() + (home.remote ? this.timings.remoteMs : this.timings.localMs);
    });
    return home.reading;
  }

  /**
   * Reads one home with a read that starts after this call. A read already in
   * flight may predate what the caller wants to observe, so it is waited out
   * first rather than joined.
   */
  async readFresh(id: string): Promise<boolean> {
    await this.homes.get(id)?.reading;
    return this.readNow(id);
  }

  /** Reads every home now, the main home first so new secondmates are included. */
  async refreshAll(): Promise<void> {
    await this.readNow(MAIN_HOME);
    await Promise.all([...this.homes.keys()].filter((id) => id !== MAIN_HOME).map((id) => this.readNow(id)));
  }

  private tick(): void {
    if (!this.active) {
      this.stop();
      return;
    }
    const now = Date.now();
    for (const home of this.homes.values()) {
      if (home.reading === null && home.dueAt <= now) void this.readNow(home.id);
    }
  }

  private command(home: HomeState): AllowedCommand {
    const { offset, sha } = this.offsets.get(home.id);
    if (home.id === MAIN_HOME) return { kind: "read-main", offset, sha };
    return { kind: home.remote ? "read-remote" : "read-local", secondmate: home.id, offset, sha };
  }

  private async readHome(home: HomeState): Promise<boolean> {
    let ok = false;
    const before = fingerprint(home);
    const eventsBefore = this.journal.events.length;
    for (let reads = 0; reads < MAX_CATCH_UP_READS; reads += 1) {
      const timeout = home.remote ? this.timings.remoteTimeoutMs : this.timings.localTimeoutMs;
      const result = await this.run(this.command(home), this.secondmates(), timeout);
      const more = result.code === 0 ? this.accept(home, result.stdout) : this.reject(home, result.stderr);
      ok = home.error === null;
      if (!more) break;
    }
    // A read that found nothing new must not look like a change, or every
    // viewer would redraw the whole page on every poll.
    if (fingerprint(home) !== before || this.journal.events.length !== eventsBefore) this.onChange();
    return ok;
  }

  private reject(home: HomeState, stderr: string): boolean {
    const notOnFork = home.remote && NOT_ON_FORK.some((text) => stderr.includes(text));
    home.version = notOnFork ? "not-on-fork" : home.version;
    if (notOnFork) home.report = null;
    home.error = stderr.trim().slice(0, ERROR_MAX) || "讀取失敗";
    return false;
  }

  /** Applies one successful read; returns whether the home has more ledger to read right away. */
  private accept(home: HomeState, stdout: string): boolean {
    const parsed = parseReport(stdout);
    if (parsed.kind === "incompatible") {
      home.version = "incompatible";
      home.report = null;
      home.error = "彙整腳本的輸出版本和看板不相容";
      return false;
    }
    if (parsed.kind === "invalid") {
      home.error = "彙整腳本的輸出不是合法的 JSON";
      return false;
    }
    const { report } = parsed;
    const rewind = this.storeLedger(home.id, report);
    home.report = report;
    home.lastOkAt = Date.now();
    home.error = null;
    if (home.id === MAIN_HOME) this.syncSecondmates(report);
    this.refreshVersions();
    return rewind || report.ledger.more;
  }

  /** Stores a read's ledger lines and cursor; returns true when the ledger must be re-read from the start. */
  private storeLedger(home: string, report: HomeReport): boolean {
    const { ledger } = report;
    if (ledger.status === "continuity-broken") {
      this.offsets.set(home, { offset: 0, sha: "-" });
      return true;
    }
    if (ledger.status === "delta" && ledger.lines.length > 0) {
      // Events first, cursor second: a crash in between re-reads this piece and
      // the journal drops the lines it already has.
      this.journal.appendLedger(home, ledger.lines);
      this.offsets.set(home, { offset: ledger.to_offset, sha: ledger.to_prefix_sha256 });
    }
    return false;
  }

  private syncSecondmates(report: HomeReport): void {
    const listed = new Set(report.secondmates.map((entry) => entry.id));
    for (const id of [...this.homes.keys()]) {
      if (id !== MAIN_HOME && !listed.has(id)) this.homes.delete(id);
    }
    for (const entry of report.secondmates) {
      const known = this.homes.get(entry.id);
      if (known === undefined) {
        this.homes.set(entry.id, { ...mainHome(), id: entry.id, remote: entry.remote, home: entry.home });
      } else {
        known.remote = entry.remote;
        known.home = entry.home;
      }
    }
  }

  private refreshVersions(): void {
    const main = this.homes.get(MAIN_HOME)?.report?.code_commit ?? "";
    for (const home of this.homes.values()) {
      if (home.report !== null) home.version = versionOf(home.id, home.report.code_commit, main);
    }
  }
}

/** Everything about a home that a viewer could see, apart from when it was last read. */
function fingerprint(home: HomeState): string {
  const { report } = home;
  const shown = report === null ? null : { ...report, ledger: null };
  return JSON.stringify([home.error, home.version, home.remote, shown]);
}

function versionOf(home: string, commit: string, mainCommit: string): HomeSnapshot["version"] {
  if (home === MAIN_HOME) return "same";
  if (mainCommit === "") return "unknown";
  return commit === mainCommit ? "same" : "different";
}
