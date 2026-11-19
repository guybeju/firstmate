// The page with an aggregator on the other side, run by browser.mjs in a
// headless Firefox for stage-7-page.sh. TB_PAGE_MODE=connected walks a board
// fed by stub-plain; TB_PAGE_MODE=alone walks a board with nothing connected.
import { execFileSync } from "node:child_process";
import fs from "node:fs";

const topic = (...args) => execFileSync(process.env.TB_TOPIC, args, { encoding: "utf8" });
const has = (text) => `document.body.innerText.includes(${JSON.stringify(text)})`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The page must never call the agent side by Firstmate's name. */
async function noFirstmate(page, where) {
  const text = await page.text();
  if (/first mate|firstmate/i.test(text)) throw new Error(`the page names Firstmate on ${where}:\n${text}`);
}

function received() {
  const file = `${process.env.TB_AGG}/received.jsonl`;
  return fs.existsSync(file)
    ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line))
    : [];
}

/** Drags a topic card onto a queue with synthetic drag events, the way stage-5-page.mjs does. */
function dropOnQueue(name, queue) {
  return `(() => {
    const card = [...document.querySelectorAll(".topic")].find((entry) => entry.innerText.includes(${JSON.stringify(name)}));
    const box = document.querySelector('.queue[data-queue="${queue}"]');
    const data = new DataTransfer();
    const fire = (target, type) => target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data, clientY: box.getBoundingClientRect().bottom - 1 }));
    fire(card, "dragstart");
    fire(box, "dragover");
    fire(box, "drop");
    fire(card, "dragend");
    return true;
  })()`;
}

async function connected(page) {
  await page.waitFor("the fed work", has("建置"));
  await page.waitFor("the fed workers", has("j1 working"), 15000);
  await noFirstmate(page, "the home page");

  // AT10.1: a drag out of later changes the order, and the toast names plain.
  await page.evaluate(dropOnQueue("之後", "normal"));
  await page.waitFor("the toast naming plain", has("會通知 plain"));
  await noFirstmate(page, "the toast");
  const listed = JSON.parse(topic("list", "--json")).find((entry) => entry.id === "later-one");
  if (listed?.queue !== "normal") throw new Error(`list --json must agree with the drag, got ${JSON.stringify(listed)}`);

  // AT10.2: 未分類 offers filing for a worker, answers for a decision, nothing for a queued item.
  await page.waitFor("the unsorted worker", has("j-loose"));
  const unsorted = await page.evaluate(`(() => {
    const rows = [...document.querySelectorAll(".row, .card, .meta")];
    // The innermost row or card that holds the text.
    const of = (text) => rows.filter((row) => row.textContent.includes(text)).sort((a, b) => a.textContent.length - b.textContent.length)[0];
    const worker = of("j-loose"), decision = of("沒有議題的決定"), queued = of("沒有議題的排隊");
    return [worker?.querySelector("select") !== null && worker !== undefined,
            decision !== undefined && [...decision.querySelectorAll("button")].some((b) => b.textContent === "要"),
            queued !== undefined && queued.querySelector("select, button, input") === null].join(",");
  })()`);
  if (unsorted !== "true,true,true") throw new Error(`未分類 must offer filing, answers, and nothing for a queued item: ${unsorted}`);

  // AT10.2: the topic page has the timeline with the summary's PR link, the
  // worker question with no answer box, and the queued list with its waiting text.
  await page.click(".topic button", "建置");
  await page.waitFor("the topic page", has("關聯 agent"));
  await page.waitFor("the summary with its PR link", `[...document.querySelectorAll("a")].some((a) => a.href === "https://example.invalid/pr/9")`);
  await page.waitFor("the worker question", has("j2 問 agent 的事"));
  const questionHasInput = await page.evaluate(`[...document.querySelectorAll(".row")].filter((row) => row.innerText.includes("j2 問 agent 的事")).some((row) => row.querySelector("input, textarea") !== null)`);
  if (questionHasInput) throw new Error("a worker question must have no answer box");
  await page.evaluate(`(() => { const s = [...document.querySelectorAll("summary")].find((e) => e.textContent.startsWith("排隊中")); if (s) s.click(); return true; })()`);
  await page.waitFor("the queued item's waiting text", has("停著：等供應商"));
  await noFirstmate(page, "the topic page");

  // AT10.3: a hold answered by its button in two steps reaches the stub.
  await page.click("button", "A");
  await page.waitFor("the confirm step", `document.querySelector(".confirm") !== null`);
  await noFirstmate(page, "the confirm step");
  if (!(await page.evaluate(has("通知 plain")))) throw new Error("the confirm step must name plain");
  await page.click(".confirm button", "送出");
  for (let tries = 0; tries < 60 && !received().some((entry) => entry.kind === "answer"); tries += 1) await sleep(150);
  const answer = received().find((entry) => entry.kind === "answer");
  if (answer?.task !== "h1" || answer?.answer !== "A") throw new Error(`the answer must reach the stub: ${JSON.stringify(answer)}`);
  await page.click("button.link", "回首頁");

  // AT10.5: the service stopped, then back; a home that stops answering goes stale.
  topic("stop");
  await page.waitFor("the red banner", has("看板服務沒有回應"), 25000);
  topic("open");
  await page.waitFor("the page to recover", `!${has("看板服務沒有回應")}`, 25000);
  // The restarted board must have read w2 once before w2 stops answering.
  await page.waitFor("w2's worker after the restart", has("w2-job"), 25000);
  fs.writeFileSync(`${process.env.TB_AGG}/control/w2`, "sleep 30\n");
  await page.waitFor("the yellow banner for w2", has("home w2 已經"), 25000);
  fs.rmSync(`${process.env.TB_AGG}/control/w2`);
  await noFirstmate(page, "the banners");

  // AT10.8: a tab open before a code change reloads itself.
  await page.evaluate("window.__beforeTheChange = true");
  execFileSync(process.env.TB_RECOMMIT);
  topic("open");
  await page.waitFor("the page to reload itself", "window.__beforeTheChange !== true", 25000);
  await page.waitFor("the reloaded page", has("建置"));
}

async function alone(page) {
  await page.waitFor("the board", has("一"));
  await page.waitFor("the not-connected note", `document.querySelector(".not-connected") !== null`);
  await page.evaluate(dropOnQueue("二", "normal"));
  await page.click(".topic button", "一");
  await page.waitFor("the topic page", has("關聯 agent"));
  await page.type(`[data-key="message:one"]`, "沒人收也要留著");
  await page.click("button", "送給 aggregator");
  await page.waitFor("the waiting message", has("等 aggregator 接上"));
  await sleep(3000);
  await page.click("button.link", "回首頁");
  await page.waitFor("the home page", has("優先順序"));
  const marks = await page.evaluate(`[document.querySelectorAll(".pill.red").length, [...document.querySelectorAll(".banner")].map((b) => b.innerText).join(" | ")].join(" # ")`);
  if (marks !== "0 # ") throw new Error(`nothing connected must show no red mark and no banner: ${marks}`);
  if (!(await page.evaluate(has("沒有接上 aggregator")))) throw new Error("the not-connected note must be shown");
  await noFirstmate(page, "the page with nothing connected");
}

export default async (page) => {
  if (process.env.TB_PAGE_MODE === "alone") await alone(page);
  else await connected(page);
};
