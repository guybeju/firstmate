// The page around the content: header, the banners that say what is wrong, and
// the choice between the home page and a topic page.
import { h } from "./dom.js";
import { home, sidebar } from "./home.js";
import { currentTopic } from "./state.js";
import { topicPage } from "./topic.js";
function staleBanner(view) {
    return view.homes
        .filter((entry) => entry.stale && entry.last_ok_seconds_ago !== null)
        .map((entry) => h("div", { class: "banner warn" }, `home ${entry.id} 已經 ${Math.round((entry.last_ok_seconds_ago ?? 0) / 60)} 分鐘沒有更新：它的 agent 燈號顯示「未知」，待決事項可能已過時。`, entry.error === null ? null : h("span", { class: "note" }, ` ${entry.error}`)));
}
const VERSION_NOTE = {
    "not-on-fork": "還沒換到 fork：在那台的 code root 加上 fork remote、寫 config/self-update-source 為「fork carry」，再回主 home 跑 /updatefirstmate。它的 agent 不會顯示。",
    incompatible: "版本不相容，它的資料沒有被使用：請在主 home 跑 /updatefirstmate。",
    different: "版本和主 home 不同（通常只是更新還沒傳到），資料照常使用。",
};
function versionBanner(view) {
    return view.homes
        .filter((entry) => VERSION_NOTE[entry.version] !== undefined)
        .map((entry) => h("div", { class: "banner warn" }, `home ${entry.id}：${VERSION_NOTE[entry.version] ?? ""}`));
}
function ledgerCommand(entry) {
    if (entry.id === "main")
        return "bin/fm-board.sh setup";
    return entry.remote
        ? `bin/fm-on.sh ${entry.id} fm-board.sh setup`
        : `bin/fm-board.sh --in-home ${entry.id} setup`;
}
function ledgerBanner(view) {
    return view.homes
        .filter((entry) => entry.ledger_enabled === false)
        .map((entry) => h("div", { class: "banner warn" }, `home ${entry.id} 的帳本未開，它的 task 不會有更新。在主 home 的終端機跑 `, h("code", {}, ledgerCommand(entry))));
}
function banners(page, actions) {
    const view = page.view;
    return [
        page.tokenBad
            ? h("div", { class: "banner" }, "token 已重置或無效，請在終端機重新跑 ", h("code", {}, "bin/fm-topic.sh open"))
            : null,
        page.down
            ? h("div", { class: "banner" }, "看板服務沒有回應。畫面是最後拿到的資料，現在送不出東西。請在終端機跑 ", h("code", {}, "bin/fm-topic.sh open"))
            : null,
        view === null ? null : [staleBanner(view), versionBanner(view), ledgerBanner(view)],
        page.notice === null
            ? null
            : h("div", { class: "banner warn" }, page.notice, " ", h("button", { class: "link", onclick: () => actions.cancel("notice") }, "知道了")),
    ];
}
export function frame(page, actions) {
    const view = page.view;
    const topic = currentTopic();
    return [
        h("header", {}, h("h1", {}, h("button", { class: "link", onclick: () => actions.open(null) }, "議題看板")), h("span", { class: "spacer" }), h("span", { class: "note" }, "每 5 秒自動更新"), h("button", { onclick: actions.refresh }, "立刻更新")),
        banners(page, actions),
        view === null
            ? h("main", {}, h("p", { class: "note" }, page.tokenBad || page.down ? "" : "載入中…"))
            : h("main", {}, topic === null
                ? h("div", { class: "side" }, sidebar(view, actions), h("div", {}, home(page, view, actions)))
                : topicPage(page, view, actions, topic)),
    ];
}
