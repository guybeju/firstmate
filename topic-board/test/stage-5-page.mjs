// The captain's path through the real page, run by browser.mjs in a headless
// Firefox. Every step waits for what the captain would see next.
import { execFileSync } from "node:child_process";

const topic = (...args) => execFileSync(process.env.TB_TOPIC, args, { encoding: "utf8" });
const has = (text) => `document.body.innerText.includes(${JSON.stringify(text)})`;
const queueHas = (queue, name) =>
  `[...document.querySelectorAll('.queue[data-queue="${queue}"] .topic')].some((card) => card.innerText.includes(${JSON.stringify(name)}))`;

/** Chooses an option of the first <select> that offers it, as a user would. */
function choose(optionText) {
  return `(() => {
    for (const select of document.querySelectorAll("select")) {
      const option = [...select.options].find((entry) => entry.textContent === ${JSON.stringify(optionText)});
      if (option) { select.value = option.value; select.dispatchEvent(new Event("change", { bubbles: true })); return true; }
    }
    return false;
  })()`;
}

/** Drags a topic card onto another card (or an empty queue) with synthetic drag events. */
function drag(name, queue, ontoName) {
  return `(() => {
    const card = [...document.querySelectorAll(".topic")].find((entry) => entry.innerText.includes(${JSON.stringify(name)}));
    const box = document.querySelector('.queue[data-queue="${queue}"]');
    const onto = ${JSON.stringify(ontoName)} === null ? box : [...box.querySelectorAll(".topic")].find((entry) => entry.innerText.includes(${JSON.stringify(ontoName)}));
    const data = new DataTransfer();
    const fire = (target, type, y) => target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data, clientY: y }));
    fire(card, "dragstart", 0);
    fire(onto, "dragover", onto.getBoundingClientRect().top + 1);
    return { card, onto, fire };
  })()`;
}

export default async function run(page) {
  await page.waitFor("the home page", has("等你決定"));
  for (const title of ["最近的結果", "進行中", "排定的", "未分類", "優先順序", "待辦（不自動開工）"]) {
    await page.waitFor(`section ${title}`, has(title));
  }
  await page.waitFor("the milestone summary", has("PR 開好了"));
  await page.waitFor("the agent", has("ship-a"));
  const rowOf = (task) =>
    `[...document.querySelectorAll(".row")].find((row) => row.innerText.includes("${task}")).innerText`;
  await page.waitFor("the worker that never started", `${rowOf("quiet-b")}.includes("還沒開始第一輪")`);
  if (await page.evaluate(`${rowOf("ship-a")}.includes("還沒開始第一輪")`))
    throw new Error("a worker that has started must not be marked as unstarted");

  // Answer the pending decision: option, then the second step with a mode.
  await page.click(".card button", "合併");
  await page.waitFor("the second step", has("送出，讓工作繼續"));
  await page.waitFor("the confirmation wording", has("看板自己不會合併或捨棄"));
  await page.click(".confirm button", "送出，讓工作繼續");
  await page.waitFor("the answer to be delivered", has("已送達"));

  // Confirm one proposal, merge the other into a topic.
  await page.click("button", "確認（放「一般」）");
  await page.waitFor("the confirmed topic in its queue", queueHas("normal", "Idea"));
  if (!(await page.evaluate(choose("Login")))) throw new Error("no merge menu offering Login");
  await page.waitFor("the merge warning", has("併入之後不能拆開"));
  await page.click(".confirm button", "併入「Login」");
  await page.waitFor("the merged proposal to disappear", `!${has("Side idea")}`);

  // Drag a topic out of "later": the order follows, and the notice is announced.
  await page.evaluate(`(() => { const d = ${drag("Parked", "high", "Login")}; d.fire(d.onto, "drop", 0); d.fire(d.card, "dragend", 0); return true; })()`);
  await page.waitFor("the dragged topic in the high queue", queueHas("high", "Parked"));
  await page.waitFor("the dispatch notice countdown", has("秒後會通知 first mate 重新評估派工"));
  const order = await page.evaluate(`[...document.querySelectorAll('.queue[data-queue="high"] .topic .name')].map((el) => el.textContent).join(",")`);
  if (order !== "Parked,Login") throw new Error(`dropping above a card must insert before it, got ${order}`);
  // A drag that ends without a drop puts the card back.
  await page.evaluate(`(() => { const d = ${drag("Parked", "later", null)}; d.fire(d.card, "dragend", 0); return true; })()`);
  await page.waitFor("the cancelled drag to snap back", queueHas("high", "Parked"));

  // The topic page: rename, message firstmate, direct message.
  await page.click(".topic button", "Billing");
  await page.waitFor("the topic page", has("關聯 agent"));
  await page.click("button", "編輯");
  await page.type('[data-key="name:billing"]', "Billing X");
  await page.click("button", "儲存");
  await page.waitFor("the new name", `document.querySelector(".titleline h2")?.textContent === "Billing X"`);
  await page.type('[data-key="message:billing"]', "先做這個");
  await page.click("button", "送給 first mate");
  await page.waitFor("the message to be delivered", `document.querySelector(".composer").innerText.includes("已送達")`);
  await page.type('[data-key="direct:main/ship-a"]', "/compact");
  await page.click("button", "直送");
  await page.waitFor("the refusal of a command-like message", has("會被當成指令"));
  await page.type('[data-key="direct:main/ship-a"]', "看一下 CI");
  await page.click("button", "直送");
  await page.waitFor("the direct message to be delivered", `[...document.querySelectorAll(".wr")].some((row) => row.innerText.includes("看一下 CI") && row.innerText.includes("已送達"))`);

  // Archive from the menu, then reopen from the sidebar.
  await page.click(".menu > button");
  await page.click(".menu .items button", "封存");
  await page.waitFor("the archive explanation", has("已經在跑的不會停"));
  await page.click(".confirm button.danger", "封存");
  await page.waitFor("the archived mark", has("已封存"));
  await page.click("button.link", "← 回首頁");
  await page.waitFor("the home page again", has("優先順序"));
  await page.click("summary", "已封存");
  await page.click("details button", "重開");
  await page.waitFor("the reopened topic in its queue", queueHas("normal", "Billing X"));
  if (process.env.TB_SHOTS) await page.screenshot(`${process.env.TB_SHOTS}/home.png`);

  // The board stops answering: the page says so, refuses to send, and recovers by itself.
  topic("stop");
  await page.waitFor("the service-down banner", has("看板服務沒有回應"), 30000);
  if (process.env.TB_SHOTS) await page.screenshot(`${process.env.TB_SHOTS}/down.png`);
  topic("open");
  await page.waitFor("the banner to clear", `!${has("看板服務沒有回應")}`, 30000);

  // The token is reset under an open page: it says so, and the new link works in the same tab.
  topic("reset-token");
  await page.waitFor("the reset-token banner", has("token 已重置或無效"), 30000);
  await page.waitFor("the board still on screen", has("優先順序"));
  const fresh = topic("open").trim();
  await page.evaluate(`void location.assign(${JSON.stringify(fresh)})`);
  await page.evaluate("void setTimeout(() => location.reload(), 0)");
  await page.waitFor("the page to load with the new token", `${has("優先順序")} && !${has("token 已重置或無效")}`, 30000);
  await page.waitFor("the token gone from the address bar", "location.hash === ''");
}
