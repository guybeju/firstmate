import { h } from "./dom.js";
import { BAD_WRITES, LIGHT_LABEL, WRITE_LABEL } from "./state.js";
const SUMMARY_LABEL = {
    ready: "就緒",
    report: "報告",
    failed: "失敗",
    landed: "落地",
};
const EVENT_LABEL = {
    "task.dispatched": "已派工",
    "task.status": "",
    "task.pr_ready": "PR 就緒",
    "task.merged": "已合併",
    "task.cleaned_up": "已清理",
};
function pad(value) {
    return String(value).padStart(2, "0");
}
export function when(epochSeconds) {
    const date = new Date(epochSeconds * 1000);
    return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
/** A PR link, only for http(s) URLs: the text comes from a ledger and must not become a script link. */
export function prLink(url) {
    if (url === null)
        return null;
    if (!/^https?:\/\//.test(url))
        return url;
    return h("a", { href: url, target: "_blank", rel: "noreferrer noopener" }, url);
}
export function topicName(view, topic) {
    return topic === null ? "未分類" : (view.topics[topic]?.name ?? topic);
}
export function topicLink(view, topic, actions) {
    if (topic === null)
        return h("span", { class: "pill" }, "未分類");
    return h("button", { class: "link", onclick: () => actions.open(topic) }, topicName(view, topic));
}
/** A text input whose content survives re-renders. */
export function draftInput(page, actions, key, placeholder, onEnter) {
    return h("input", {
        type: "text",
        "data-key": key,
        placeholder,
        value: page.drafts.get(key) ?? "",
        oninput: (event) => actions.draft(key, event.target.value),
        onkeydown: (event) => {
            if (event.key === "Enter" && onEnter !== undefined)
                onEnter();
        },
    });
}
function writeRow(page, actions, write) {
    const bad = BAD_WRITES.includes(write.state);
    const key = `resend:${write.id}`;
    const asking = page.pending.has(key);
    return h("div", { class: bad ? "wr bad" : "wr" }, h("span", { class: "pill" }, WRITE_LABEL[write.state] ?? write.state), " ", write.text, write.state === "retrying"
        ? h("span", { class: "note" }, `（第 ${write.attempt} 次重試）`)
        : null, write.error === null ? null : h("div", { class: "note" }, write.error), bad && !asking
        ? h("span", { class: "btns" }, h("button", { onclick: () => actions.resend(write) }, "重送"), h("button", { onclick: () => actions.ignore(write) }, "忽略"))
        : null, asking
        ? h("div", { class: "confirm" }, "這筆不知道有沒有送到，重送可能會重複送出。", h("span", { class: "btns" }, h("button", { class: "danger", onclick: () => actions.confirm(key) }, "還是重送"), h("button", { onclick: () => actions.cancel(key) }, "取消")))
        : null);
}
/** The status lines of the writes that match, newest first, shown where they were sent from. */
export function writeRows(page, actions, matches) {
    const writes = (page.view?.writes ?? []).filter((write) => matches(write) && write.state !== "ignored");
    return writes
        .toSorted((a, b) => b.created_at - a.created_at)
        .slice(0, 5)
        .map((write) => writeRow(page, actions, write));
}
function answerConfirm(page, actions, key) {
    const pending = page.pending.get(key);
    if (pending === undefined)
        return null;
    const seconds = Math.max(0, Math.round((pending.expiresAt - Date.now()) / 1000));
    return h("div", { class: "confirm" }, h("div", {}, `你的答覆：「${String(pending.body["answer"])}」`), h("div", { class: "note" }, `會記成你的答覆並通知 first mate。看板自己不會合併或捨棄。這次確認還有 ${seconds} 秒有效。`), h("div", { class: "btns" }, h("button", { class: "danger", onclick: () => actions.confirm(key, { mode: "done" }) }, "送出，這件事結束"), h("button", { class: "danger", onclick: () => actions.confirm(key, { mode: "release" }) }, "送出，讓工作繼續"), h("button", { onclick: () => actions.cancel(key) }, "取消")), h("div", { class: "note" }, "「這件事結束」用在純粹的決定；「讓工作繼續」用在還有工作沒做完的項目，例如同意合併。"));
}
function holdMeta(view, actions, hold, showTopic) {
    return h("div", { class: "meta" }, showTopic ? topicLink(view, hold.topic, actions) : null, h("span", { class: "pill" }, hold.home), h("span", { class: "note" }, hold.task), hold.live ? null : h("span", { class: "pill warn" }, `暫緩：${hold.deferred_reason ?? ""}`), hold.stale ? h("span", { class: "pill warn" }, "可能已過時") : null);
}
/** True for a hands-on item the captain still has to act on. */
export function needsCaptain(hold) {
    return hold.todo !== null && hold.todo.state !== "claimed";
}
/** The hands-on items in play, the ones waiting on the captain first. */
export function liveTodos(view, topic) {
    const todos = view.holds.filter((hold) => hold.todo !== null && hold.live && (topic === undefined || hold.topic === topic));
    return [...todos.filter(needsCaptain), ...todos.filter((hold) => !needsCaptain(hold))];
}
/** Copies the commands; a browser that refuses gets them selected, ready for the copy key. */
function copyCommand(command, button) {
    navigator.clipboard.writeText(command).then(() => {
        button.textContent = "已複製";
    }, () => {
        const block = button.parentElement?.querySelector("pre");
        if (block !== null && block !== undefined)
            getSelection()?.selectAllChildren(block);
        button.textContent = "已選取，請按 Ctrl+C（Mac 是 ⌘C）";
    });
}
const TODO_NOTE = {
    open: () => null,
    claimed: () => h("div", { class: "wr" }, "你已按做完了，等 first mate 驗證"),
    rejected: (reason) => h("div", { class: "wr bad" }, `first mate 驗證沒過：${reason}`),
    obsolete: (reason) => h("div", { class: "wr" }, `first mate：不再需要了。${reason}`),
};
function todoButtons(actions, hold, todo, key) {
    const close = (answer) => actions.ask(key, "holds/answer", { home: hold.home, task: hold.task, answer, label: answer });
    if (todo.state === "claimed")
        return null;
    if (todo.state === "obsolete")
        return h("div", { class: "btns" }, h("button", { onclick: () => close("撤下") }, "好，撤下"));
    return h("div", { class: "btns" }, h("button", { onclick: () => actions.claim(hold.task) }, "做完了"), h("button", { onclick: () => close("不做了") }, "不做了"));
}
function todoConfirm(page, actions, key) {
    const pending = page.pending.get(key);
    if (pending === undefined)
        return null;
    return h("div", { class: "confirm" }, `會記成你的答覆「${String(pending.body["answer"])}」，這一項就從看板拿掉，並通知 first mate。`, h("div", { class: "btns" }, h("button", { class: "danger", onclick: () => actions.confirm(key, { mode: "done" }) }, "確定"), h("button", { onclick: () => actions.cancel(key) }, "取消")));
}
/** Something the captain has to do by hand: what, the commands to copy, and where it stands. */
function todoCard(page, view, actions, hold, todo, showTopic) {
    const key = `answer:${hold.home}/${hold.task}`;
    return h("div", { class: "card todo", "data-todo": hold.task }, holdMeta(view, actions, hold, showTopic), h("b", {}, hold.title), TODO_NOTE[todo.state](todo.reason ?? ""), h("div", {}, todo.what), todo.command === ""
        ? null
        : h("div", {}, h("pre", { class: "cmd" }, todo.command), h("button", {
            onclick: (event) => copyCommand(todo.command, event.currentTarget),
        }, "複製指令")), todoButtons(actions, hold, todo, key), todoConfirm(page, actions, key), writeRows(page, actions, (write) => write.kind === "answer" && write.home === hold.home && write.task === hold.task));
}
export function holdCard(page, view, actions, hold, showTopic) {
    if (hold.todo !== null)
        return todoCard(page, view, actions, hold, hold.todo, showTopic);
    const key = `answer:${hold.home}/${hold.task}`;
    const draftKey = `answer-text:${hold.home}/${hold.task}`;
    const ask = (answer, label) => {
        if (answer.trim() !== "")
            actions.ask(key, "holds/answer", {
                home: hold.home,
                task: hold.task,
                answer: answer.trim(),
                label,
            });
    };
    const askTyped = () => ask(page.drafts.get(draftKey) ?? "", "文字作答");
    return h("div", { class: "card" }, holdMeta(view, actions, hold, showTopic), h("b", {}, hold.title), h("pre", { class: "q" }, hold.question), h("div", { class: "btns" }, hold.options.map((option) => h("button", { onclick: () => ask(option, option) }, option))), h("div", { class: "btns" }, draftInput(page, actions, draftKey, "用文字回答", askTyped), h("button", { onclick: askTyped }, "送出")), answerConfirm(page, actions, key), writeRows(page, actions, (write) => write.kind === "answer" && write.home === hold.home && write.task === hold.task));
}
export function questionRow(view, actions, question, showTopic) {
    return h("div", { class: "row" }, h("span", { class: "pill" }, "first mate 處理中"), h("span", { class: "grow" }, `${question.home}/${question.task}：${question.summary}`), showTopic ? topicLink(view, question.topic, actions) : null);
}
export function light(agent) {
    return [h("span", { class: `dot l-${agent.light}` }), LIGHT_LABEL[agent.light] ?? agent.light];
}
/** What to say about a worker whose harness has not taken its first turn. */
function unstartedNote(agent) {
    const since = agent.updated_at === null ? "" : `${when(agent.updated_at)} 派出後`;
    return `${since}還沒開始第一輪，停太久就是卡在啟動畫面`;
}
export function agentRow(view, actions, agent) {
    return h("div", { class: "row" }, h("span", {}, light(agent)), h("span", { class: "grow" }, h("b", {}, agent.task), " ", h("span", { class: "note" }, `${agent.state} ${agent.detail}`), agent.unstarted ? [" ", h("span", { class: "pill warn" }, unstartedNote(agent))] : null), h("span", { class: "pill" }, agent.home), agent.stale ? h("span", { class: "pill warn" }, "資料過期") : null, topicLink(view, agent.topic, actions));
}
export function summaryRow(view, actions, summary, showTopic) {
    return h("div", { class: summary.kind === "failed" ? "upd summary failed" : "upd summary" }, h("span", { class: "t" }, when(summary.ts)), h("span", { class: "pill" }, SUMMARY_LABEL[summary.kind] ?? summary.kind), " ", showTopic ? [topicLink(view, summary.topic, actions), " "] : null, h("span", { class: "note" }, `${summary.home}/${summary.task}`), h("div", {}, summary.text), prLink(summary.pr));
}
export function updateRow(update) {
    const label = update.source === "board" ? "" : (EVENT_LABEL[update.event] ?? update.event);
    return h("div", { class: update.source === "board" ? "upd system" : "upd" }, h("span", { class: "t" }, when(update.ts)), update.task === null
        ? null
        : h("span", { class: "note" }, `${update.home ?? ""}/${update.task} `), [label, update.text].filter((part) => part !== "").join(" "), update.pr === null ? null : [" ", prLink(update.pr)]);
}
