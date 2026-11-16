// What the page remembers between renders, and the actions its buttons call.
import type { Queue } from "#board/topics.js";
import type { BoardView } from "#board/view.js";

export interface WriteView {
  id: string;
  kind: "note" | "send" | "relay" | "answer" | "tag";
  home: string;
  task: string | null;
  topic: string | null;
  text: string;
  state: string;
  error: string | null;
  attempt: number;
  next_at: number | null;
  created_at: number;
}

export type View = BoardView & {
  boot_id: string;
  version: string;
  polling: boolean;
  writes: WriteView[];
};

/** The first half of a two-step action, waiting for the captain to confirm. */
export interface Pending {
  path: string;
  body: Record<string, unknown>;
  confirm: string;
  expiresAt: number;
}

export interface Page {
  view: View | null;
  /** The board stopped answering; the view on screen is the last one received. */
  down: boolean;
  tokenBad: boolean;
  /** Text typed into inputs, by input key, so a re-render does not lose it. */
  drafts: Map<string, string>;
  pending: Map<string, Pending>;
  /** Fields being edited in place: "name:<topic>" or "goal:<topic>". */
  editing: Set<string>;
  /** Which small panel is open on the topic page: the menu, or one of its two questions. */
  panel: "menu" | "archive" | "merge" | null;
  /** The last refusal from the board, shown until the next action. */
  notice: string | null;
}

export interface Actions {
  open: (topic: string | null) => void;
  refresh: () => void;
  draft: (key: string, value: string) => void;
  setPanel: (panel: Page["panel"]) => void;
  edit: (key: string, on: boolean) => void;
  topic: (op: string, body: Record<string, unknown>) => void;
  move: (topic: string, queue: Queue, before: string | null) => void;
  /** Asks the board for a confirmation code; the action runs when `confirm` is called with the same key. */
  ask: (key: string, path: string, body: Record<string, unknown>) => void;
  confirm: (key: string, extra?: Record<string, unknown>) => void;
  cancel: (key: string) => void;
  message: (topic: string, key: string) => void;
  direct: (home: string, task: string, key: string) => void;
  tag: (home: string, task: string, topic: string) => void;
  resend: (write: WriteView) => void;
  ignore: (write: WriteView) => void;
}

/** The queues in display order. Kept here because page scripts cannot load modules outside dist/page. */
export const QUEUES: readonly Queue[] = ["high", "normal", "later"];
export const QUEUE_LABEL: Record<Queue, string> = { high: "高", normal: "一般", later: "待辦" };
export const LIGHT_LABEL: Record<string, string> = {
  decide: "待你決定",
  stuck: "卡住",
  working: "進行中",
  done: "完成",
  unknown: "未知",
};
export const WRITE_LABEL: Record<string, string> = {
  sending: "送出中",
  retrying: "重試中",
  delivered: "已送達",
  handled_elsewhere: "已由別處處理",
  failed: "失敗",
  undelivered: "未送達",
  unknown: "結果不明",
  ignored: "已忽略",
};
export const BAD_WRITES = ["failed", "undelivered", "unknown"];

export function currentTopic(): string | null {
  const match = /^#\/topic\/(.+)$/.exec(location.hash);
  return match === null ? null : decodeURIComponent(match[1] as string);
}
