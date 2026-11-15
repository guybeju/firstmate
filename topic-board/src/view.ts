// Computes what the board shows from what the service knows. Pure: the same
// inputs always give the same view.
import type { JournalEvent, LedgerEvent, Summary } from "./journal.js";
import type { HomeReport, ReportHold } from "./report.js";
import { QUEUES, resolveTopicId } from "./topics.js";
import type { Queue, TopicState } from "./topics.js";

export type Light = "decide" | "stuck" | "working" | "done" | "unknown";
export type HomeVersion = "same" | "different" | "incompatible" | "not-on-fork" | "unknown";

/** What the poller knows about one home. */
export interface HomeSnapshot {
  id: string;
  remote: boolean;
  report: HomeReport | null;
  /** Milliseconds since the epoch of the last successful read, or null. */
  lastOkAt: number | null;
  error: string | null;
  version: HomeVersion;
}

export interface ViewInput {
  topics: TopicState;
  homes: HomeSnapshot[];
  events: JournalEvent[];
  summaries: Summary[];
  nowMs: number;
  staleMs: number;
}

export type Placement = { topic: string; reason: null } | { topic: null; reason: "no-tag" | "unknown-topic" | "proposed" };

export interface HomeView {
  id: string;
  remote: boolean;
  version: HomeVersion;
  ledger_enabled: boolean | null;
  stale: boolean;
  last_ok_seconds_ago: number | null;
  error: string | null;
}

export interface AgentView {
  home: string;
  task: string;
  kind: string;
  light: Light;
  state: string;
  detail: string;
  topic: string | null;
  unsorted_reason: string | null;
  updated_at: number | null;
  stale: boolean;
}

export interface HoldView {
  home: string;
  task: string;
  title: string;
  question: string;
  options: string[];
  live: boolean;
  deferred_reason: string | null;
  topic: string | null;
  stale: boolean;
}

export interface QuestionView {
  home: string;
  task: string;
  key: string;
  summary: string;
  topic: string | null;
}

export interface UpdateView {
  ts: number;
  source: "ledger" | "board";
  home: string | null;
  task: string | null;
  event: string;
  text: string;
  pr: string | null;
  topic: string | null;
}

export interface SummaryView {
  ts: number;
  home: string;
  task: string;
  kind: string;
  text: string;
  pr: string | null;
  topic: string | null;
}

export interface TopicView {
  name: string;
  goal: string;
  status: "proposed" | "confirmed" | "archived";
  queue: Queue | null;
  /** For a proposal: the queue firstmate suggested, which confirming uses by default. */
  suggested_queue: Queue | null;
  close_reason: string | null;
  archived_at: string | null;
}

export interface BoardView {
  homes: HomeView[];
  queues: Record<Queue, string[]>;
  topics: Record<string, TopicView>;
  agents: AgentView[];
  holds: HoldView[];
  questions: QuestionView[];
  updates: UpdateView[];
  summaries: SummaryView[];
}

const MAX_UPDATES = 2000;
// Upstream keeps a hold reason on the backlog item's title line, so a reason
// written as several lines may reach the board as one. The marker is therefore
// accepted anywhere in the last line, not only at its start.
const OPTION_MARKER = "選項：";

interface Tag {
  topic: string;
  atMs: number;
}

/** Parses a tag file: one "<topic-id> <UTC time>" per line, oldest first. */
export function parseTags(text: string): Tag[] {
  const tags: Tag[] = [];
  for (const line of text.split("\n")) {
    const [topic, time] = line.trim().split(" ");
    if (topic === undefined || topic === "") continue;
    const atMs = Date.parse(time ?? "");
    tags.push({ topic, atMs: Number.isNaN(atMs) ? 0 : atMs });
  }
  return tags;
}

/** The option buttons a hold asks for: what follows "選項：" at the end of its last line, split on " | ". */
export function parseOptions(question: string): string[] {
  const lastLine = question.trimEnd().split("\n").pop() ?? "";
  const at = lastLine.lastIndexOf(OPTION_MARKER);
  if (at === -1) return [];
  const options = lastLine
    .slice(at + OPTION_MARKER.length)
    .split(" | ")
    .map((option) => option.trim());
  return options.length >= 2 && options.every((option) => option !== "") ? options : [];
}

function lightFor(state: string): Light {
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

function deferredReason(hold: ReportHold): string | null {
  switch (hold.hold_bucket) {
    case "live":
      return null;
    case "aged":
      return "已放超過 14 天";
    case "dated":
      return `延到 ${hold.hold_until ?? "之後"}`;
    case "blocked":
      return `等 ${hold.unresolved_blocker_ids.join("、")} 完成`;
  }
}

/** Looks up topics for tasks across every home's tag files. */
class Placer {
  private readonly tags = new Map<string, Tag[]>();

  constructor(
    private readonly topics: TopicState,
    homes: HomeSnapshot[],
  ) {
    for (const home of homes) {
      for (const [task, text] of Object.entries(home.report?.topics ?? {})) {
        this.tags.set(`${home.id}\n${task}`, parseTags(text));
      }
    }
  }

  private classify(tagged: string | undefined): Placement {
    if (tagged === undefined) return { topic: null, reason: "no-tag" };
    const id = resolveTopicId(this.topics.doc, tagged);
    if (this.topics.archive.topics[id] !== undefined) return { topic: id, reason: null };
    const topic = this.topics.doc.topics[id];
    if (topic === undefined) return { topic: null, reason: "unknown-topic" };
    return topic.status === "confirmed" ? { topic: id, reason: null } : { topic: null, reason: "proposed" };
  }

  /** The topic a task belongs to now. */
  current(home: string, task: string): Placement {
    return this.classify(this.tags.get(`${home}\n${task}`)?.at(-1)?.topic);
  }

  /** The topic a task belonged to at `atMs`: the last tag written by then, else its first tag. */
  at(home: string, task: string, atMs: number): Placement {
    const tags = this.tags.get(`${home}\n${task}`) ?? [];
    const inEffect = tags.filter((tag) => tag.atMs <= atMs).at(-1) ?? tags[0];
    return this.classify(inEffect?.topic);
  }
}

/** Where one task belongs right now, given what the homes last reported. */
export function placeTask(topics: TopicState, homes: HomeSnapshot[], home: string, task: string): Placement {
  return new Placer(topics, homes).current(home, task);
}

function homeView(home: HomeSnapshot, input: ViewInput): HomeView {
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

function ledgerEvents(input: ViewInput): LedgerEvent[] {
  return input.events.filter((event): event is LedgerEvent => event.src === "ledger");
}

/** The last ledger event of every (home, task). */
function lastEvents(events: LedgerEvent[]): Map<string, LedgerEvent> {
  const last = new Map<string, LedgerEvent>();
  for (const event of events) last.set(`${event.home}\n${event.task}`, event);
  return last;
}

/** Builds agent entries for one home; everything that does not vary per task is bound here. */
function agentMaker(home: HomeSnapshot, stale: boolean, placer: Placer, last: Map<string, LedgerEvent>) {
  return (task: string, kind: string, light: Light, state: string, detail: string): AgentView => {
    const placement = placer.current(home.id, task);
    return {
      home: home.id,
      task,
      kind,
      light: stale ? "unknown" : light,
      state,
      detail,
      topic: placement.topic,
      unsorted_reason: placement.reason,
      updated_at: last.get(`${home.id}\n${task}`)?.ts ?? null,
      stale,
    };
  };
}

function agentsOf(home: HomeSnapshot, stale: boolean, placer: Placer, last: Map<string, LedgerEvent>): AgentView[] {
  const report = home.report;
  if (report === null) return [];
  const agent = agentMaker(home, stale, placer, last);
  const deciding = new Set(report.holds.filter((hold) => hold.hold_bucket === "live").map((hold) => hold.id));
  const running = report.tasks
    .filter((task) => task.kind !== "secondmate")
    .map((task) =>
      agent(task.id, task.kind, deciding.has(task.id) ? "decide" : lightFor(task.state), task.state, task.detail),
    );
  // A cleaned-up task is gone from the snapshot; its last ledger event says how it ended.
  const known = new Set(report.tasks.map((task) => task.id));
  const ended = [...last.values()]
    .filter((event) => event.home === home.id && !known.has(event.task))
    .map((event) => {
      const outcome = event.event === "task.merged" || event.event === "task.cleaned_up" ? "done" : "unknown";
      return agent(event.task, "", outcome, outcome, "");
    });
  return [...running, ...ended];
}

function holdsOf(home: HomeSnapshot, stale: boolean, placer: Placer): HoldView[] {
  return (home.report?.holds ?? []).map((hold) => {
    const own = placer.current(home.id, hold.id);
    const placement = own.topic === null && hold.origin !== "" ? placer.current(home.id, hold.origin) : own;
    return {
      home: home.id,
      task: hold.id,
      title: hold.title,
      question: hold.question,
      options: parseOptions(hold.question),
      live: hold.hold_bucket === "live",
      deferred_reason: deferredReason(hold),
      topic: placement.topic,
      stale,
    };
  });
}

/** Sort key for a hold: live first, then the topic's queue order, then oldest first. */
function holdRank(view: BoardView, hold: HoldView, ageDays: number): number[] {
  const queue = hold.topic === null ? null : (view.topics[hold.topic]?.queue ?? null);
  if (queue === null || hold.topic === null) return [hold.live ? 0 : 1, QUEUES.length, 0, -ageDays];
  return [hold.live ? 0 : 1, QUEUES.indexOf(queue), view.queues[queue].indexOf(hold.topic), -ageDays];
}

function compareRanks(left: number[], right: number[]): number {
  for (let index = 0; index < left.length; index += 1) {
    const difference = (left[index] as number) - (right[index] as number);
    if (difference !== 0) return difference;
  }
  return 0;
}

function holdOrder(view: BoardView, ages: Map<HoldView, number>): (a: HoldView, b: HoldView) => number {
  return (a, b) =>
    compareRanks(holdRank(view, a, ages.get(a) ?? 0), holdRank(view, b, ages.get(b) ?? 0)) ||
    a.task.localeCompare(b.task);
}

function prOf(event: LedgerEvent): string | null {
  const pr = event.fields["pr"];
  return typeof pr === "string" ? pr : null;
}

function ledgerText(event: LedgerEvent): string {
  const text = event.fields["text"];
  const state = event.fields["state"];
  if (event.event === "task.status") {
    return `${typeof state === "string" ? `${state}：` : ""}${typeof text === "string" ? text.trim() : ""}`;
  }
  return "";
}

function updatesOf(input: ViewInput, placer: Placer): UpdateView[] {
  const updates = input.events.map((event): UpdateView => {
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
  return updates.sort((a, b) => b.ts - a.ts).slice(0, MAX_UPDATES);
}

/** The PR a `ready` or `landed` summary refers to: the task's latest PR event at or before it. */
function prForSummary(summary: Summary, events: LedgerEvent[]): string | null {
  if (summary.kind !== "ready" && summary.kind !== "landed") return null;
  const candidates = events.filter(
    (event) =>
      event.home === summary.home &&
      event.task === summary.task &&
      event.ts <= summary.ts &&
      (event.event === "task.pr_ready" || event.event === "task.merged"),
  );
  const latest = candidates.at(-1);
  return latest === undefined ? null : prOf(latest);
}

function topicViews(topics: TopicState): Record<string, TopicView> {
  const views: Record<string, TopicView> = {};
  for (const [id, topic] of Object.entries(topics.doc.topics)) {
    views[id] = {
      name: topic.name,
      goal: topic.goal,
      status: topic.status,
      queue: QUEUES.find((queue) => topics.doc.queues[queue].includes(id)) ?? null,
      suggested_queue: topic.suggested_queue ?? null,
      close_reason: topic.close_proposal?.reason ?? null,
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

export function buildView(input: ViewInput): BoardView {
  const placer = new Placer(input.topics, input.homes);
  const ledger = ledgerEvents(input);
  const last = lastEvents(ledger);
  const homes = input.homes.map((home) => homeView(home, input));
  const view: BoardView = {
    homes,
    queues: structuredClone(input.topics.doc.queues),
    topics: topicViews(input.topics),
    agents: [],
    holds: [],
    questions: [],
    updates: updatesOf(input, placer),
    summaries: input.summaries
      .map((summary) => ({
        ...summary,
        pr: prForSummary(summary, ledger),
        topic: placer.current(summary.home, summary.task).topic,
      }))
      .sort((a, b) => b.ts - a.ts),
  };
  const ages = new Map<HoldView, number>();
  input.homes.forEach((home, index) => {
    const stale = (homes[index] as HomeView).stale;
    view.agents.push(...agentsOf(home, stale, placer, last));
    const holds = holdsOf(home, stale, placer);
    holds.forEach((hold, at) => ages.set(hold, home.report?.holds[at]?.hold_age_days ?? 0));
    view.holds.push(...holds);
    for (const question of home.report?.status_decisions ?? []) {
      view.questions.push({
        home: home.id,
        task: question.id,
        key: question.key,
        summary: question.summary,
        topic: placer.current(home.id, question.id).topic,
      });
    }
  });
  view.holds.sort(holdOrder(view, ages));
  return view;
}
