// Building blocks shared by the home page and the topic page.
import type { AgentView, HoldView, QuestionView, SummaryView, UpdateView } from "#board/view.js";
import { h } from "./dom.js";
import type { Child } from "./dom.js";
import { BAD_WRITES, LIGHT_LABEL, WRITE_LABEL } from "./state.js";
import type { Actions, Page, View, WriteView } from "./state.js";

const SUMMARY_LABEL: Record<string, string> = {
  ready: "就緒",
  report: "報告",
  failed: "失敗",
  landed: "落地",
};
const EVENT_LABEL: Record<string, string> = {
  "task.dispatched": "已派工",
  "task.status": "",
  "task.pr_ready": "PR 就緒",
  "task.merged": "已合併",
  "task.cleaned_up": "已清理",
};

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

export function when(epochSeconds: number): string {
  const date = new Date(epochSeconds * 1000);
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** A PR link, only for http(s) URLs: the text comes from a ledger and must not become a script link. */
export function prLink(url: string | null): Child {
  if (url === null) return null;
  if (!/^https?:\/\//.test(url)) return url;
  return h("a", { href: url, target: "_blank", rel: "noreferrer noopener" }, url);
}

export function topicName(view: View, topic: string | null): string {
  return topic === null ? "未分類" : (view.topics[topic]?.name ?? topic);
}

export function topicLink(view: View, topic: string | null, actions: Actions): Child {
  if (topic === null) return h("span", { class: "pill" }, "未分類");
  return h("button", { class: "link", onclick: () => actions.open(topic) }, topicName(view, topic));
}

/** A text input whose content survives re-renders. */
export function draftInput(
  page: Page,
  actions: Actions,
  key: string,
  placeholder: string,
  onEnter?: () => void,
): HTMLElement {
  return h("input", {
    type: "text",
    "data-key": key,
    placeholder,
    value: page.drafts.get(key) ?? "",
    oninput: (event) => actions.draft(key, (event.target as HTMLInputElement).value),
    onkeydown: (event) => {
      if ((event as KeyboardEvent).key === "Enter" && onEnter !== undefined) onEnter();
    },
  });
}

function writeRow(page: Page, actions: Actions, write: WriteView): Child {
  const bad = BAD_WRITES.includes(write.state);
  const key = `resend:${write.id}`;
  const asking = page.pending.has(key);
  return h(
    "div",
    { class: bad ? "wr bad" : "wr" },
    h("span", { class: "pill" }, WRITE_LABEL[write.state] ?? write.state),
    " ",
    write.text,
    write.state === "retrying"
      ? h("span", { class: "note" }, `（第 ${write.attempt} 次重試）`)
      : null,
    write.error === null ? null : h("div", { class: "note" }, write.error),
    bad && !asking
      ? h(
          "span",
          { class: "btns" },
          h("button", { onclick: () => actions.resend(write) }, "重送"),
          h("button", { onclick: () => actions.ignore(write) }, "忽略"),
        )
      : null,
    asking
      ? h(
          "div",
          { class: "confirm" },
          "這筆不知道有沒有送到，重送可能會重複送出。",
          h(
            "span",
            { class: "btns" },
            h("button", { class: "danger", onclick: () => actions.confirm(key) }, "還是重送"),
            h("button", { onclick: () => actions.cancel(key) }, "取消"),
          ),
        )
      : null,
  );
}

/** The status lines of the writes that match, newest first, shown where they were sent from. */
export function writeRows(
  page: Page,
  actions: Actions,
  matches: (write: WriteView) => boolean,
): Child {
  const writes = (page.view?.writes ?? []).filter(
    (write) => matches(write) && write.state !== "ignored",
  );
  return writes
    .toSorted((a, b) => b.created_at - a.created_at)
    .slice(0, 5)
    .map((write) => writeRow(page, actions, write));
}

function answerConfirm(page: Page, actions: Actions, key: string): Child {
  const pending = page.pending.get(key);
  if (pending === undefined) return null;
  const seconds = Math.max(0, Math.round((pending.expiresAt - Date.now()) / 1000));
  return h(
    "div",
    { class: "confirm" },
    h("div", {}, `你的答覆：「${String(pending.body["answer"])}」`),
    h(
      "div",
      { class: "note" },
      `會記成你的答覆並通知 first mate。看板自己不會合併或捨棄。這次確認還有 ${seconds} 秒有效。`,
    ),
    h(
      "div",
      { class: "btns" },
      h(
        "button",
        { class: "danger", onclick: () => actions.confirm(key, { mode: "done" }) },
        "送出，這件事結束",
      ),
      h(
        "button",
        { class: "danger", onclick: () => actions.confirm(key, { mode: "release" }) },
        "送出，讓工作繼續",
      ),
      h("button", { onclick: () => actions.cancel(key) }, "取消"),
    ),
    h(
      "div",
      { class: "note" },
      "「這件事結束」用在純粹的決定；「讓工作繼續」用在還有工作沒做完的項目，例如同意合併。",
    ),
  );
}

function holdMeta(view: View, actions: Actions, hold: HoldView, showTopic: boolean): Child {
  return h(
    "div",
    { class: "meta" },
    showTopic ? topicLink(view, hold.topic, actions) : null,
    h("span", { class: "pill" }, hold.home),
    h("span", { class: "note" }, hold.task),
    hold.live ? null : h("span", { class: "pill warn" }, `暫緩：${hold.deferred_reason ?? ""}`),
    hold.stale ? h("span", { class: "pill warn" }, "可能已過時") : null,
  );
}

export function holdCard(
  page: Page,
  view: View,
  actions: Actions,
  hold: HoldView,
  showTopic: boolean,
): Child {
  const key = `answer:${hold.home}/${hold.task}`;
  const draftKey = `answer-text:${hold.home}/${hold.task}`;
  const ask = (answer: string, label: string): void => {
    if (answer.trim() !== "")
      actions.ask(key, "holds/answer", {
        home: hold.home,
        task: hold.task,
        answer: answer.trim(),
        label,
      });
  };
  const askTyped = (): void => ask(page.drafts.get(draftKey) ?? "", "文字作答");
  return h(
    "div",
    { class: "card" },
    holdMeta(view, actions, hold, showTopic),
    h("b", {}, hold.title),
    h("pre", { class: "q" }, hold.question),
    h(
      "div",
      { class: "btns" },
      hold.options.map((option) => h("button", { onclick: () => ask(option, option) }, option)),
    ),
    h(
      "div",
      { class: "btns" },
      draftInput(page, actions, draftKey, "用文字回答", askTyped),
      h("button", { onclick: askTyped }, "送出"),
    ),
    answerConfirm(page, actions, key),
    writeRows(
      page,
      actions,
      (write) => write.kind === "answer" && write.home === hold.home && write.task === hold.task,
    ),
  );
}

export function questionRow(
  view: View,
  actions: Actions,
  question: QuestionView,
  showTopic: boolean,
): Child {
  return h(
    "div",
    { class: "row" },
    h("span", { class: "pill" }, "first mate 處理中"),
    h("span", { class: "grow" }, `${question.home}/${question.task}：${question.summary}`),
    showTopic ? topicLink(view, question.topic, actions) : null,
  );
}

export function light(agent: AgentView): Child {
  return [h("span", { class: `dot l-${agent.light}` }), LIGHT_LABEL[agent.light] ?? agent.light];
}

/** What to say about a worker whose harness has not taken its first turn. */
function unstartedNote(agent: AgentView): string {
  const since = agent.updated_at === null ? "" : `${when(agent.updated_at)} 派出後`;
  return `${since}還沒開始第一輪，停太久就是卡在啟動畫面`;
}

export function agentRow(view: View, actions: Actions, agent: AgentView): Child {
  return h(
    "div",
    { class: "row" },
    h("span", {}, light(agent)),
    h(
      "span",
      { class: "grow" },
      h("b", {}, agent.task),
      " ",
      h("span", { class: "note" }, `${agent.state} ${agent.detail}`),
      agent.unstarted ? [" ", h("span", { class: "pill warn" }, unstartedNote(agent))] : null,
    ),
    h("span", { class: "pill" }, agent.home),
    agent.stale ? h("span", { class: "pill warn" }, "資料過期") : null,
    topicLink(view, agent.topic, actions),
  );
}

export function summaryRow(
  view: View,
  actions: Actions,
  summary: SummaryView,
  showTopic: boolean,
): Child {
  return h(
    "div",
    { class: summary.kind === "failed" ? "upd summary failed" : "upd summary" },
    h("span", { class: "t" }, when(summary.ts)),
    h("span", { class: "pill" }, SUMMARY_LABEL[summary.kind] ?? summary.kind),
    " ",
    showTopic ? [topicLink(view, summary.topic, actions), " "] : null,
    h("span", { class: "note" }, `${summary.home}/${summary.task}`),
    h("div", {}, summary.text),
    prLink(summary.pr),
  );
}

export function updateRow(update: UpdateView): Child {
  const label = update.source === "board" ? "" : (EVENT_LABEL[update.event] ?? update.event);
  return h(
    "div",
    { class: update.source === "board" ? "upd system" : "upd" },
    h("span", { class: "t" }, when(update.ts)),
    update.task === null
      ? null
      : h("span", { class: "note" }, `${update.home ?? ""}/${update.task} `),
    [label, update.text].filter((part) => part !== "").join(" "),
    update.pr === null ? null : [" ", prLink(update.pr)],
  );
}
