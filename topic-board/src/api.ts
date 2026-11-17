// The browser API: what each /api/ route does once a request has passed the
// checks in http.ts. Topic operations are the same ones fm-topic.sh uses.
import * as actions from "./actions.js";
import type { ActionContext, ActionResult } from "./actions.js";
import { bindingOf } from "./confirm.js";
import type { ConfirmStore } from "./confirm.js";
import { textField } from "./files.js";
import type { ApiHandler, ApiReply } from "./http.js";
import type { BoardResponse } from "./protocol.js";
import type { WriteEngine } from "./writes.js";

/** What the API needs from the running service. */
export interface ApiHost {
  bootId: string;
  version: () => string;
  view: () => Record<string, unknown>;
  /** Records that a viewer is present, which keeps polling going. */
  touch: () => void;
  refresh: () => Promise<void>;
  topicOp: (op: string, args: Record<string, unknown>) => BoardResponse;
  actionContext: () => ActionContext;
  writes: WriteEngine;
  confirm: ConfirmStore;
}

type Body = Record<string, unknown>;
type Route = (host: ApiHost, body: Body, query: URLSearchParams) => ApiReply | Promise<ApiReply>;

function ok(body: Record<string, unknown> = {}): ApiReply {
  return { status: 200, body: { ok: true, ...body } };
}

function fail(status: number, error: string, message: string): ApiReply {
  return { status, body: { error, message } };
}

function field(body: Body, name: string): string {
  return textField(body, name);
}

function fromTopicOp(response: BoardResponse): ApiReply {
  if (response.ok) return ok({ line: response.line });
  return response.code === "usage"
    ? fail(400, "usage", response.line)
    : fail(409, "refused", response.line);
}

function fromAction(result: ActionResult): ApiReply {
  return result.ok ? ok({ write_id: result.write.id }) : fail(409, "refused", result.line);
}

function fromProblem(problem: string | null): ApiReply {
  return problem === null ? ok() : fail(409, "refused", problem);
}

/** A topic route: the body goes to the topic operation of the same name. */
function topicRoute(op: string): Route {
  return (host, body) => fromTopicOp(host.topicOp(op, body));
}

const state: Route = (host, _body, query) => {
  host.touch();
  const current = `${host.bootId}:${host.version()}`;
  return query.get("v") === current
    ? ok({ changed: false })
    : ok({ changed: true, ...host.view() });
};

const refresh: Route = async (host) => {
  host.touch();
  await host.refresh();
  return ok();
};

/** A drop with no "before" lands at the end of the queue. */
const move: Route = (host, body) =>
  fromTopicOp(host.topicOp("move", body["before"] === undefined ? { ...body, last: true } : body));

/**
 * Runs `act` only on the second of two requests. The first request, without a
 * code, gets one bound to `binding`; the second must return it for the same
 * binding.
 */
function twoStep(host: ApiHost, body: Body, binding: string, act: () => ApiReply): ApiReply {
  const code = body["confirm"];
  if (code === undefined) return ok({ ...host.confirm.issue(binding) });
  if (typeof code !== "string" || !host.confirm.redeem(code, binding)) {
    return fail(409, "confirm", "確認已失效或對象變了，請重新操作一次。");
  }
  return act();
}

const merge: Route = (host, body) => {
  const from = field(body, "from");
  const into = field(body, "into");
  return twoStep(host, body, bindingOf("merge", from, into), () =>
    fromTopicOp(host.topicOp("merge", { from, into })),
  );
};

function holdQuestion(context: ActionContext, home: string, task: string): string | null {
  const hold = actions.findHold(context, home, task);
  return hold === undefined ? null : hold.question;
}

/** Answering closes or releases the hold and cannot be taken back, so it always takes two steps. */
const answer: Route = (host, body) => {
  const context = host.actionContext();
  const home = field(body, "home");
  const task = field(body, "task");
  const text = field(body, "answer");
  const question = holdQuestion(context, home, task);
  if (question === null)
    return fail(409, "refused", "這個待決事項已經不在了（可能已經有人答了）。");
  return twoStep(host, body, bindingOf("answer", home, task, question, text), () => {
    const mode = actions.ANSWER_MODES.find((name) => name === body["mode"]);
    if (mode === undefined) return fail(400, "usage", "要選「這件事結束」或「讓工作繼續」。");
    return fromAction(
      actions.answer(
        context,
        { home, task, answer: text, label: field(body, "label"), mode },
        "browser",
      ),
    );
  });
};

/** Resending a write whose outcome is unknown may duplicate it, so that case takes two steps. */
const resend: Route = (host, body) => {
  const id = field(body, "write_id");
  const record = host.writes.records.get(id);
  const unknown = record !== undefined && record.state === "unknown";
  const act = (): ApiReply => fromProblem(host.writes.resend(id, unknown));
  return unknown ? twoStep(host, body, bindingOf("resend", id), act) : act();
};

const ROUTES: Record<string, Route> = {
  "GET state": state,
  "POST refresh": refresh,
  "POST topics/confirm": topicRoute("confirm"),
  "POST topics/move": move,
  "POST topics/rename": topicRoute("rename"),
  "POST topics/goal": topicRoute("goal"),
  "POST topics/archive": topicRoute("archive"),
  "POST topics/reopen": topicRoute("reopen"),
  "POST topics/keep": topicRoute("keep"),
  "POST topics/merge": merge,
  "POST agents/tag": (host, body) =>
    fromAction(
      actions.tagAgent(
        host.actionContext(),
        field(body, "home"),
        field(body, "task"),
        field(body, "topic"),
        "browser",
      ),
    ),
  "POST messages": (host, body) =>
    fromAction(
      actions.message(host.actionContext(), field(body, "topic"), field(body, "text"), "browser"),
    ),
  "POST direct": (host, body) =>
    fromAction(
      actions.direct(
        host.actionContext(),
        field(body, "home"),
        field(body, "task"),
        field(body, "text"),
        "browser",
      ),
    ),
  "POST holds/answer": answer,
  "POST todos/claim": (host, body) =>
    fromTopicOp(host.topicOp("todo-claim", { task: field(body, "task") })),
  "POST writes/resend": resend,
  "POST writes/ignore": (host, body) => fromProblem(host.writes.ignore(field(body, "write_id"))),
};

export function createApi(host: ApiHost): ApiHandler {
  return async (method, route, query, body) => {
    const handler = ROUTES[`${method} ${route}`];
    return handler === undefined
      ? fail(404, "not-found", "沒有這個 API。")
      : handler(host, body, query);
  };
}
