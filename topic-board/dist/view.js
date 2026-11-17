// Computes what the board shows from what the service knows. Pure: the same
// inputs always give the same view.
import { MAIN_HOME } from "./journal.js";
import { orNull } from "./files.js";
import { QUEUES, resolveTopicId } from "./topics.js";
const MAX_UPDATES = 2000;
// Upstream keeps a hold reason on the backlog item's title line, so a reason
// written as several lines may reach the board as one. The marker is therefore
// accepted anywhere in the last line, not only at its start.
const OPTION_MARKER = "選項：";
/** A hold reason that starts with this asks the captain to do something by hand. */
export const TODO_MARKER = "動手：";
/** Splits a hands-on hold's reason into what to do (its first line) and the commands (the rest). */
export function parseTodo(question) {
    if (!question.startsWith(TODO_MARKER))
        return null;
    const [first = "", ...rest] = question.slice(TODO_MARKER.length).split("\n");
    return { what: first.trim(), command: rest.join("\n").replace(/\s+$/, "") };
}
function todoView(home, hold, marks) {
    const text = home === MAIN_HOME ? parseTodo(hold.question) : null;
    if (text === null)
        return null;
    const mark = Object.hasOwn(marks, hold.id) ? marks[hold.id] : undefined;
    return { ...text, state: mark?.state ?? "open", reason: mark?.reason ?? null };
}
/** Parses a tag file: one "<topic-id> <UTC time>" per line, oldest first. */
export function parseTags(text) {
    const tags = [];
    for (const line of text.split("\n")) {
        const [topic, time] = line.trim().split(" ");
        if (topic === undefined || topic === "")
            continue;
        const atMs = time === undefined ? Number.NaN : Date.parse(time);
        tags.push({ topic, atMs: Number.isNaN(atMs) ? 0 : atMs });
    }
    return tags;
}
/** The option buttons a hold asks for: what follows "選項：" at the end of its last line, split on " | ". */
export function parseOptions(question) {
    const lines = question.trimEnd().split("\n");
    const lastLine = lines[lines.length - 1];
    const at = lastLine.lastIndexOf(OPTION_MARKER);
    if (at === -1)
        return [];
    const options = lastLine
        .slice(at + OPTION_MARKER.length)
        .split(" | ")
        .map((option) => option.trim());
    return options.length >= 2 && options.every((option) => option !== "") ? options : [];
}
function lightFor(state) {
    switch (state) {
        case "blocked":
        case "failed":
            return "stuck";
        case "working":
        case "parked":
        case "paused":
            return "working";
        case "done":
            return "done";
        default:
            return "unknown";
    }
}
function deferredReason(hold) {
    switch (hold.hold_bucket) {
        case "live":
            return null;
        case "aged":
            return "已放超過 14 天";
        case "dated":
            return `延到 ${hold.hold_until === null ? "之後" : hold.hold_until}`;
        case "blocked":
            return `等 ${hold.unresolved_blocker_ids.join("、")} 完成`;
    }
}
function waitingFor(home, item) {
    const todo = home === MAIN_HOME && item.hold !== null && parseTodo(item.hold) !== null;
    if (item.captain)
        return todo ? "要你動手" : "等你決定";
    if (item.hold !== null)
        return `停著：${item.hold}`;
    if (item.blockers.length > 0)
        return `等 ${item.blockers.join("、")} 完成`;
    return null;
}
/** Looks up topics for tasks across every home's tag files. */
class Placer {
    topics;
    tags = new Map();
    constructor(topics, homes) {
        this.topics = topics;
        for (const home of homes) {
            if (home.report === null)
                continue;
            for (const [task, text] of Object.entries(home.report.topics)) {
                this.tags.set(`${home.id}\n${task}`, parseTags(text));
            }
        }
    }
    tagsOf(home, task) {
        const tags = this.tags.get(`${home}\n${task}`);
        return tags === undefined ? [] : tags;
    }
    classify(tagged) {
        if (tagged === undefined)
            return { topic: null, reason: "no-tag" };
        const id = resolveTopicId(this.topics.doc, tagged);
        if (this.topics.archive.topics[id] !== undefined)
            return { topic: id, reason: null };
        const topic = this.topics.doc.topics[id];
        if (topic === undefined)
            return { topic: null, reason: "unknown-topic" };
        return topic.status === "confirmed"
            ? { topic: id, reason: null }
            : { topic: null, reason: "proposed" };
    }
    /** The topic a task belongs to now. */
    current(home, task) {
        const tags = this.tagsOf(home, task);
        return this.classify(tags[tags.length - 1]?.topic);
    }
    /** The topic a task belonged to at `atMs`: the last tag written by then, else its first tag. */
    at(home, task, atMs) {
        const tags = this.tagsOf(home, task);
        const written = tags.filter((tag) => tag.atMs <= atMs);
        const inEffect = written.length > 0 ? written[written.length - 1] : tags[0];
        return this.classify(inEffect?.topic);
    }
}
/** Where one task belongs right now, given what the homes last reported. */
export function placeTask(topics, homes, home, task) {
    return new Placer(topics, homes).current(home, task);
}
function homeView(home, input) {
    const age = home.lastOkAt === null ? null : input.nowMs - home.lastOkAt;
    return {
        id: home.id,
        remote: home.remote,
        version: home.version,
        ledger_enabled: home.report?.ledger_enabled ?? null,
        stale: age === null || age > input.staleMs,
        last_ok_seconds_ago: age === null ? null : Math.floor(age / 1000),
        error: home.error,
    };
}
function ledgerEvents(input) {
    return input.events.filter((event) => event.src === "ledger");
}
/** The last ledger event of every (home, task). */
function lastEvents(events) {
    const last = new Map();
    for (const event of events)
        last.set(`${event.home}\n${event.task}`, event);
    return last;
}
/** The run each (home, task) is on: everything since its latest dispatch. */
function currentRuns(events) {
    const runs = new Map();
    for (const event of events) {
        const key = `${event.home}\n${event.task}`;
        if (event.event === "task.dispatched") {
            const kind = event.fields["kind"];
            runs.set(key, { kind: typeof kind === "string" ? kind : "", merged: false });
        }
        else if (event.event === "task.merged") {
            runs.set(key, { kind: runs.get(key)?.kind ?? "", merged: true });
        }
    }
    return runs;
}
const DISCARDED = { state: "discarded", detail: "已收掉，帳本裡沒有落地紀錄" };
/**
 * How a task that is gone from the snapshot ended, from its last ledger event.
 * Teardown records the same event whether the work landed or was thrown away,
 * so a ship task cleaned up with no merge in its run is not shown as done.
 */
function endedTask(event, run) {
    const base = { id: event.task, kind: run?.kind ?? "", source: "", detail: "", unstarted: false };
    const cleaned = event.event === "task.cleaned_up";
    if (cleaned && run?.kind === "ship" && !run.merged)
        return { task: { ...base, ...DISCARDED }, light: "unknown" };
    const light = cleaned || event.event === "task.merged" ? "done" : "unknown";
    return { task: { ...base, state: light }, light };
}
/** Builds agent entries for one home; everything that does not vary per task is bound here. */
function agentMaker(home, stale, placer, last) {
    return (task, light) => {
        const placement = placer.current(home.id, task.id);
        const lastEvent = last.get(`${home.id}\n${task.id}`);
        return {
            home: home.id,
            task: task.id,
            kind: task.kind,
            light: stale ? "unknown" : light,
            state: task.state,
            detail: task.detail,
            topic: placement.topic,
            unsorted_reason: placement.reason,
            updated_at: lastEvent === undefined ? null : lastEvent.ts,
            stale,
            unstarted: task.unstarted,
        };
    };
}
function agentsOf(home, stale, placer, last, runs) {
    const report = home.report;
    if (report === null)
        return [];
    const agent = agentMaker(home, stale, placer, last);
    const deciding = new Set(report.holds.filter((hold) => hold.hold_bucket === "live").map((hold) => hold.id));
    const running = report.tasks
        .filter((task) => task.kind !== "secondmate")
        .map((task) => agent(task, deciding.has(task.id) ? "decide" : lightFor(task.state)));
    // A cleaned-up task is gone from the snapshot; its last ledger event says how it ended.
    const known = new Set(report.tasks.map((task) => task.id));
    const ended = [...last.values()]
        .filter((event) => event.home === home.id && !known.has(event.task))
        .map((event) => {
        const gone = endedTask(event, runs.get(`${event.home}\n${event.task}`));
        return agent(gone.task, gone.light);
    });
    return [...running, ...ended];
}
function holdsOf(home, stale, placer, marks) {
    if (home.report === null)
        return [];
    return home.report.holds.map((hold) => {
        const todo = todoView(home.id, hold, marks);
        const own = placer.current(home.id, hold.id);
        const placement = own.topic === null && hold.origin !== "" ? placer.current(home.id, hold.origin) : own;
        return {
            ageDays: hold.hold_age_days === null ? 0 : hold.hold_age_days,
            view: {
                home: home.id,
                task: hold.id,
                title: hold.title,
                question: hold.question,
                options: todo === null ? parseOptions(hold.question) : [],
                todo,
                // Something to do by hand does not become less due by sitting there.
                live: hold.hold_bucket === "live" || (todo !== null && hold.hold_bucket === "aged"),
                deferred_reason: todo !== null && hold.hold_bucket === "aged" ? null : deferredReason(hold),
                topic: placement.topic,
                stale,
            },
        };
    });
}
/** Sort key for a hold: live first, then the topic's queue order, then oldest first. */
function holdRank(view, { view: hold, ageDays }) {
    const live = hold.live ? 0 : 1;
    const queue = hold.topic === null ? null : view.topics[hold.topic].queue;
    // A hold with no topic, or whose topic is archived, sorts after every queue.
    if (hold.topic === null || queue === null)
        return [live, QUEUES.length, QUEUES.length, -ageDays];
    return [live, QUEUES.indexOf(queue), view.queues[queue].indexOf(hold.topic), -ageDays];
}
function compareRanks(left, right) {
    for (const [index, value] of left.entries()) {
        const difference = value - right[index];
        if (difference !== 0)
            return difference;
    }
    return 0;
}
function holdOrder(view) {
    return (a, b) => compareRanks(holdRank(view, a), holdRank(view, b)) || a.view.task.localeCompare(b.view.task);
}
function prOf(event) {
    const pr = event.fields["pr"];
    return typeof pr === "string" ? pr : null;
}
function ledgerText(event) {
    const text = event.fields["text"];
    const state = event.fields["state"];
    if (event.event === "task.status") {
        return `${typeof state === "string" ? `${state}：` : ""}${typeof text === "string" ? text.trim() : ""}`;
    }
    return "";
}
function updatesOf(input, placer) {
    const updates = input.events.map((event) => {
        if (event.src === "board") {
            return {
                ts: event.ts,
                source: "board",
                home: event.home,
                task: event.task,
                event: event.kind,
                text: event.text,
                pr: null,
                topic: event.topic === null ? null : resolveTopicId(input.topics.doc, event.topic),
            };
        }
        return {
            ts: event.ts,
            source: "ledger",
            home: event.home,
            task: event.task,
            event: event.event,
            text: ledgerText(event),
            pr: prOf(event),
            topic: placer.at(event.home, event.task, event.ts * 1000).topic,
        };
    });
    return updates.toSorted((a, b) => b.ts - a.ts).slice(0, MAX_UPDATES);
}
/** The PR a `ready` or `landed` summary refers to: the task's latest PR event at or before it. */
function prForSummary(summary, events) {
    if (summary.kind !== "ready" && summary.kind !== "landed")
        return null;
    const candidates = events.filter((event) => event.home === summary.home &&
        event.task === summary.task &&
        event.ts <= summary.ts &&
        (event.event === "task.pr_ready" || event.event === "task.merged"));
    const latest = candidates.at(-1);
    return latest === undefined ? null : prOf(latest);
}
function topicViews(topics) {
    const views = {};
    for (const [id, topic] of Object.entries(topics.doc.topics)) {
        views[id] = {
            name: topic.name,
            goal: topic.goal,
            status: topic.status,
            queue: orNull(QUEUES.find((queue) => topics.doc.queues[queue].includes(id))),
            suggested_queue: orNull(topic.suggested_queue),
            close_reason: topic.close_proposal === undefined ? null : topic.close_proposal.reason,
            archived_at: null,
        };
    }
    for (const [id, topic] of Object.entries(topics.archive.topics)) {
        views[id] = {
            name: topic.name,
            goal: topic.goal,
            status: "archived",
            queue: null,
            suggested_queue: null,
            close_reason: null,
            archived_at: topic.archived_at,
        };
    }
    return views;
}
export function buildView(input) {
    const placer = new Placer(input.topics, input.homes);
    const ledger = ledgerEvents(input);
    const last = lastEvents(ledger);
    const runs = currentRuns(ledger);
    const homes = input.homes.map((home) => homeView(home, input));
    const view = {
        homes,
        queues: structuredClone(input.topics.doc.queues),
        topics: topicViews(input.topics),
        agents: [],
        queued: [],
        holds: [],
        questions: [],
        updates: updatesOf(input, placer),
        summaries: input.summaries
            .map((summary) => ({
            ...summary,
            pr: prForSummary(summary, ledger),
            topic: placer.current(summary.home, summary.task).topic,
        }))
            .toSorted((a, b) => b.ts - a.ts),
    };
    const ranked = [];
    input.homes.forEach((home, index) => {
        const stale = homes[index].stale;
        view.agents.push(...agentsOf(home, stale, placer, last, runs));
        ranked.push(...holdsOf(home, stale, placer, input.topics.doc.todos));
        if (home.report === null)
            return;
        for (const item of home.report.queued) {
            view.queued.push({
                home: home.id,
                task: item.id,
                kind: item.kind,
                title: item.title,
                topic: placer.current(home.id, item.id).topic,
                waiting: waitingFor(home.id, item),
            });
        }
        for (const question of home.report.status_decisions) {
            view.questions.push({
                home: home.id,
                task: question.id,
                key: question.key,
                summary: question.summary,
                topic: placer.current(home.id, question.id).topic,
            });
        }
    });
    view.holds = ranked.toSorted(holdOrder(view)).map((entry) => entry.view);
    return view;
}
