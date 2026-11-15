import { MAIN_HOME } from "./journal.js";
import { parseReport } from "./report.js";
export const DEFAULT_TIMINGS = {
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
function mainHome() {
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
    run;
    journal;
    offsets;
    timings;
    onChange;
    homes = new Map([[MAIN_HOME, mainHome()]]);
    lastViewerAt = 0;
    timer = null;
    constructor(run, journal, offsets, timings, onChange) {
        this.run = run;
        this.journal = journal;
        this.offsets = offsets;
        this.timings = timings;
        this.onChange = onChange;
    }
    /** True while a viewer asked for the board recently enough to keep polling. */
    get active() {
        return Date.now() - this.lastViewerAt < this.timings.idleMs;
    }
    /** Records that someone is looking, which starts or continues scheduled polling. */
    touch() {
        this.lastViewerAt = Date.now();
        this.timer ??= setInterval(() => this.tick(), TICK_MS);
    }
    stop() {
        if (this.timer !== null)
            clearInterval(this.timer);
        this.timer = null;
    }
    snapshots() {
        return [...this.homes.values()].map(({ id, remote, report, lastOkAt, error, version }) => ({
            id,
            remote,
            report,
            lastOkAt,
            error,
            version,
        }));
    }
    secondmates() {
        return [...this.homes.values()]
            .filter((home) => home.id !== MAIN_HOME)
            .map((home) => ({ id: home.id, remote: home.remote, home: home.home }));
    }
    hasMainReport() {
        return this.homes.get(MAIN_HOME)?.report != null;
    }
    knows(home) {
        return this.homes.has(home);
    }
    /** Reads one home now (joining a read already in flight); resolves to whether it succeeded. */
    readNow(id) {
        const home = this.homes.get(id);
        if (home === undefined)
            return Promise.resolve(false);
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
    async readFresh(id) {
        await this.homes.get(id)?.reading;
        return this.readNow(id);
    }
    /** Reads every home now, the main home first so new secondmates are included. */
    async refreshAll() {
        await this.readNow(MAIN_HOME);
        await Promise.all([...this.homes.keys()].filter((id) => id !== MAIN_HOME).map((id) => this.readNow(id)));
    }
    tick() {
        if (!this.active) {
            this.stop();
            return;
        }
        const now = Date.now();
        for (const home of this.homes.values()) {
            if (home.reading === null && home.dueAt <= now)
                void this.readNow(home.id);
        }
    }
    command(home) {
        const { offset, sha } = this.offsets.get(home.id);
        if (home.id === MAIN_HOME)
            return { kind: "read-main", offset, sha };
        return { kind: home.remote ? "read-remote" : "read-local", secondmate: home.id, offset, sha };
    }
    async readHome(home) {
        let ok = false;
        const before = fingerprint(home);
        const eventsBefore = this.journal.events.length;
        for (let reads = 0; reads < MAX_CATCH_UP_READS; reads += 1) {
            const timeout = home.remote ? this.timings.remoteTimeoutMs : this.timings.localTimeoutMs;
            const result = await this.run(this.command(home), this.secondmates(), timeout);
            const more = result.code === 0 ? this.accept(home, result.stdout) : this.reject(home, result.stderr);
            ok = home.error === null;
            if (!more)
                break;
        }
        // A read that found nothing new must not look like a change, or every
        // viewer would redraw the whole page on every poll.
        if (fingerprint(home) !== before || this.journal.events.length !== eventsBefore)
            this.onChange();
        return ok;
    }
    reject(home, stderr) {
        const notOnFork = home.remote && NOT_ON_FORK.some((text) => stderr.includes(text));
        home.version = notOnFork ? "not-on-fork" : home.version;
        if (notOnFork)
            home.report = null;
        home.error = stderr.trim().slice(0, ERROR_MAX) || "讀取失敗";
        return false;
    }
    /** Applies one successful read; returns whether the home has more ledger to read right away. */
    accept(home, stdout) {
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
        if (home.id === MAIN_HOME)
            this.syncSecondmates(report);
        this.refreshVersions();
        return rewind || report.ledger.more;
    }
    /** Stores a read's ledger lines and cursor; returns true when the ledger must be re-read from the start. */
    storeLedger(home, report) {
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
    syncSecondmates(report) {
        const listed = new Set(report.secondmates.map((entry) => entry.id));
        for (const id of [...this.homes.keys()]) {
            if (id !== MAIN_HOME && !listed.has(id))
                this.homes.delete(id);
        }
        for (const entry of report.secondmates) {
            const known = this.homes.get(entry.id);
            if (known === undefined) {
                this.homes.set(entry.id, { ...mainHome(), id: entry.id, remote: entry.remote, home: entry.home });
            }
            else {
                known.remote = entry.remote;
                known.home = entry.home;
            }
        }
    }
    refreshVersions() {
        const main = this.homes.get(MAIN_HOME)?.report?.code_commit ?? "";
        for (const home of this.homes.values()) {
            if (home.report !== null)
                home.version = versionOf(home.id, home.report.code_commit, main);
        }
    }
}
/** Everything about a home that a viewer could see, apart from when it was last read. */
function fingerprint(home) {
    const { report } = home;
    const shown = report === null ? null : { ...report, ledger: null };
    return JSON.stringify([home.error, home.version, home.remote, shown]);
}
function versionOf(home, commit, mainCommit) {
    if (home === MAIN_HOME)
        return "same";
    if (mainCommit === "")
        return "unknown";
    return commit === mainCommit ? "same" : "different";
}
