// Drives a headless Firefox through WebDriver BiDi, with nothing but Node
// built-ins, so the page can be checked the way the captain uses it.
//
// Usage: node browser.mjs <url> <script.mjs>
// The script's default export receives { evaluate, waitFor, click, type,
// screenshot, text } and may throw to fail.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [url, scriptFile] = process.argv.slice(2);
// Snap-packaged Firefox cannot read hidden directories in the home directory.
const profile = fs.mkdtempSync(path.join(os.homedir(), "tb-firefox-tmp-"));
const port = 20000 + Math.floor(Math.random() * 20000);
const firefox = spawn("firefox", ["--headless", "--no-remote", "--profile", profile, `--remote-debugging-port=${port}`, "about:blank"], { stdio: "ignore" });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function connect() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/session`);
      await new Promise((resolve, reject) => {
        socket.onopen = resolve;
        socket.onerror = reject;
      });
      return socket;
    } catch {
      await sleep(200);
    }
  }
  throw new Error("firefox did not open its BiDi port");
}

let exitCode = 0;
try {
  const socket = await connect();
  let nextId = 1;
  const waiting = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    const pending = waiting.get(message.id);
    if (pending === undefined) return;
    waiting.delete(message.id);
    if (message.type === "error") pending.reject(new Error(`${message.error}: ${message.message}`));
    else pending.resolve(message.result);
  };
  const send = (method, params) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      waiting.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });

  await send("session.new", { capabilities: {} });
  const { contexts } = await send("browsingContext.getTree", {});
  const context = contexts[0].context;
  await send("browsingContext.setViewport", { context, viewport: { width: 1300, height: 950 } });
  await send("browsingContext.navigate", { context, url, wait: "complete" });

  const evaluate = async (expression) => {
    const reply = await send("script.evaluate", { expression, target: { context }, awaitPromise: true, resultOwnership: "none" });
    if (reply.type === "exception") throw new Error(reply.exceptionDetails.text);
    return reply.result.value;
  };
  const tools = {
    evaluate,
    text: () => evaluate("document.body.innerText"),
    async waitFor(description, expression, timeoutMs = 8000) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (await evaluate(`Boolean(${expression})`)) return;
        await sleep(150);
      }
      throw new Error(`timed out waiting for: ${description}\n--- page text ---\n${await tools.text()}`);
    },
    /** Clicks the first element matching `selector` whose text contains `label`. */
    async click(selector, label = "") {
      const found = await evaluate(`(() => { const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((e) => e.textContent.includes(${JSON.stringify(label)})); if (!el) return false; el.click(); return true; })()`);
      if (!found) throw new Error(`nothing to click: ${selector} "${label}"\n--- page text ---\n${await tools.text()}`);
    },
    async type(selector, value) {
      const found = await evaluate(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return false; el.focus(); el.value = ${JSON.stringify(value)}; el.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`);
      if (!found) throw new Error(`nothing to type into: ${selector}`);
    },
    async screenshot(file) {
      const { data } = await send("browsingContext.captureScreenshot", { context });
      fs.writeFileSync(file, Buffer.from(data, "base64"));
    },
  };
  const script = await import(pathToFileURL(path.resolve(scriptFile)).href);
  await script.default(tools);
  console.log("ok - browser script finished");
} catch (error) {
  console.error(`not ok - ${error.message}`);
  exitCode = 1;
} finally {
  firefox.kill("SIGKILL");
  await sleep(300);
  fs.rmSync(profile, { recursive: true, force: true });
}
process.exit(exitCode);
