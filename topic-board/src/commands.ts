// The only external commands the board service may run. The list is fixed
// here, never read from configuration. Every command is built as an argument
// array for execFile (no shell), runs a script from the code root's bin/, and
// gets FM_HOME set to the main home.
import { execFile } from "node:child_process";
import path from "node:path";
import type { BoardConfig } from "./layout.js";

export interface Secondmate {
  id: string;
  remote: boolean;
  home: string;
}

export type ReadCommand =
  | { kind: "read-main"; offset: number; sha: string }
  | { kind: "read-local"; secondmate: string; offset: number; sha: string }
  | { kind: "read-remote"; secondmate: string; offset: number; sha: string };

/** Where a hold answer or a tag is written: the main home, a local secondmate home, or a remote one. */
export type Placement = "main" | "local" | "remote";

export type WriteCommand =
  | { kind: "note"; requestId: string; body: string }
  | { kind: "send"; task: string; text: string }
  | { kind: "relay"; secondmate: string; deliveryId: string; text: string }
  | { kind: "answer"; placement: Placement; secondmate?: string; line: string }
  | { kind: "tag"; placement: Placement; secondmate?: string; task: string; topic: string };

export type AllowedCommand = ReadCommand | WriteCommand;

export interface CommandResult {
  /** The exit code, or null when the command could not run or was killed. */
  code: number | null;
  stdout: string;
  stderr: string;
}

interface Invocation {
  script: string;
  args: string[];
  stdin?: string;
}

const ID = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/;
const SHA = /^(-|[0-9a-f]{64})$/;
const REQUEST_ID = /^[A-Za-z0-9_][A-Za-z0-9._:-]{0,127}$/;
const DELIVERY_ID = /^[a-f0-9]{16}$/;
const ANSWER_MODES = ["done", "release"];
const MAX_OUTPUT_BYTES = 4 * 1024 * 1024;

export class CommandRefused extends Error {}

function refuse(reason: string): never {
  throw new CommandRefused(reason);
}

function readArgs(command: ReadCommand): string[] {
  if (!Number.isInteger(command.offset) || command.offset < 0)
    refuse("offset must be a non-negative integer");
  if (!SHA.test(command.sha)) refuse("prefix hash must be 64 hex characters or '-'");
  return [String(command.offset), command.sha];
}

/** Checks that `id` is a registered secondmate of the expected placement. */
function secondmateArg(id: string, remote: boolean, known: Secondmate[]): string {
  if (!ID.test(id)) refuse(`malformed secondmate id: ${id}`);
  const found = known.find((entry) => entry.id === id);
  if (found === undefined) refuse(`unknown secondmate: ${id}`);
  if (found.remote !== remote) refuse(`secondmate ${id} is ${found.remote ? "remote" : "local"}`);
  return id;
}

function idArg(value: string, what: string): string {
  if (!ID.test(value)) refuse(`malformed ${what}: ${value}`);
  return value;
}

/**
 * Text handed to fm-send.sh as one argument. fm-send.sh treats a leading '-'
 * as an option and has no "--" terminator, and types text starting with '/' or
 * '$' into the pane as a command, so none of the three may lead.
 */
export function directTextProblem(text: string): string | null {
  if (text.trim() === "") return "訊息不能是空的。";
  if (/^[/$-]/.test(text)) {
    return "以 / 或 $ 開頭會被當成指令。要跑指令請到終端機，要傳文字請在開頭加字。";
  }
  return null;
}

function sendText(text: string): string {
  const problem = directTextProblem(text);
  if (problem !== null) refuse(problem);
  return text;
}

/** One `<task-id>\t<answer>\t<label>\t<mode>` line for fm-captain-hold.sh answers. */
function answerLine(line: string): string {
  const fields = line.split("\t");
  const [task = "", answer = "", , mode = ""] = fields;
  if (/[\r\n]/.test(line) || fields.length !== 4)
    refuse("an answer must be one line of four tab-separated fields");
  if (!ID.test(task) || answer === "" || !ANSWER_MODES.includes(mode))
    refuse("malformed answer line");
  return `${line}\n`;
}

/** The secondmate argument a placed command needs: none for the main home. */
function placed(
  command: { placement: Placement; secondmate?: string },
  known: Secondmate[],
): string {
  if (command.placement === "main") return "";
  const secondmate = command.secondmate === undefined ? "" : command.secondmate;
  return secondmateArg(secondmate, command.placement === "remote", known);
}

function answerInvocation(
  command: Extract<WriteCommand, { kind: "answer" }>,
  known: Secondmate[],
): Invocation {
  const stdin = answerLine(command.line);
  const secondmate = placed(command, known);
  const answers = ["fm-captain-hold.sh", "answers", "--source", "topic-board"];
  switch (command.placement) {
    case "main":
      return { script: answers[0] as string, args: answers.slice(1), stdin };
    case "local":
      return { script: "fm-topic.sh", args: ["--in-home", secondmate, "answers"], stdin };
    case "remote":
      return { script: "fm-on.sh", args: ["--stdin", secondmate, ...answers], stdin };
  }
}

function tagInvocation(
  command: Extract<WriteCommand, { kind: "tag" }>,
  known: Secondmate[],
): Invocation {
  const tag = ["tag", idArg(command.task, "task id"), idArg(command.topic, "topic id")];
  const secondmate = placed(command, known);
  switch (command.placement) {
    case "main":
      return { script: "fm-topic.sh", args: tag };
    case "local":
      return { script: "fm-topic.sh", args: ["--in-home", secondmate, ...tag] };
    case "remote":
      return { script: "fm-on.sh", args: [secondmate, "fm-topic.sh", ...tag] };
  }
}

function relayInvocation(
  command: Extract<WriteCommand, { kind: "relay" }>,
  known: Secondmate[],
): Invocation {
  if (!DELIVERY_ID.test(command.deliveryId))
    refuse("delivery id must be 16 lowercase hex characters");
  if (!known.some((entry) => entry.id === command.secondmate))
    refuse(`unknown secondmate: ${command.secondmate}`);
  return {
    script: "fm-send.sh",
    args: [
      idArg(command.secondmate, "secondmate id"),
      "--fire-and-forget",
      command.deliveryId,
      sendText(command.text),
    ],
  };
}

function readInvocation(command: ReadCommand, known: Secondmate[]): Invocation {
  switch (command.kind) {
    case "read-main":
      return { script: "fm-topic-board-read.sh", args: readArgs(command) };
    case "read-local":
      return {
        script: "fm-topic-board-read.sh",
        args: ["--in-home", secondmateArg(command.secondmate, false, known), ...readArgs(command)],
      };
    case "read-remote":
      return {
        script: "fm-on.sh",
        args: [
          secondmateArg(command.secondmate, true, known),
          "fm-topic-board-read.sh",
          ...readArgs(command),
        ],
      };
  }
}

function writeInvocation(command: WriteCommand, known: Secondmate[]): Invocation {
  switch (command.kind) {
    case "note":
      if (!REQUEST_ID.test(command.requestId)) refuse("malformed request id");
      return {
        script: "fm-inbox.sh",
        args: ["note", "--request-id", command.requestId, "-"],
        stdin: command.body,
      };
    case "send":
      return {
        script: "fm-send.sh",
        args: [idArg(command.task, "task id"), sendText(command.text)],
      };
    case "relay":
      return relayInvocation(command, known);
    case "answer":
      return answerInvocation(command, known);
    case "tag":
      return tagInvocation(command, known);
  }
}

const READ_KINDS = ["read-main", "read-local", "read-remote"];

/** Turns an allowed command into the script and arguments to run; throws CommandRefused otherwise. */
export function invocationFor(command: AllowedCommand, known: Secondmate[]): Invocation {
  return READ_KINDS.includes(command.kind)
    ? readInvocation(command as ReadCommand, known)
    : writeInvocation(command as WriteCommand, known);
}

export type CommandRunner = (
  command: AllowedCommand,
  known: Secondmate[],
  timeoutMs: number,
) => Promise<CommandResult>;

/** Builds the runner bound to one home and code root. */
export function commandRunner(config: BoardConfig): CommandRunner {
  return (command, known, timeoutMs) =>
    new Promise((resolve) => {
      let invocation: Invocation;
      try {
        invocation = invocationFor(command, known);
      } catch (error) {
        resolve({ code: null, stdout: "", stderr: (error as Error).message });
        return;
      }
      const child = execFile(
        path.join(config.root, "bin", invocation.script),
        invocation.args,
        {
          env: { ...process.env, FM_HOME: config.home },
          timeout: timeoutMs,
          maxBuffer: MAX_OUTPUT_BYTES,
          encoding: "utf8",
        },
        (error, stdout, stderr) => {
          const code = error === null ? 0 : typeof error.code === "number" ? error.code : null;
          resolve({
            code,
            stdout,
            stderr: error !== null && code === null ? `${stderr}${error.message}` : stderr,
          });
        },
      );
      if (child.stdin !== null) child.stdin.end(invocation.stdin);
    });
}
