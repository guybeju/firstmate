// The only external commands the board service may run: the aggregator's feed
// and its deliverer, both one program fixed here, never read from
// configuration (contracts section 7). Every run is an argument array for
// execFile (no shell), and gets MYSHAPE_HOME set to the board's home.
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
/** The aggregator's program, relative to the code root. */
export const AGGREGATOR_PROGRAM = path.join("bin", "fm-board.sh");
const HOME_ID = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/;
const SHA = /^(-|[0-9a-f]{64})$/;
const MAX_OUTPUT_BYTES = 4 * 1024 * 1024;
export class CommandRefused extends Error {
}
function refuse(reason) {
    throw new CommandRefused(reason);
}
/**
 * Text handed to an agent. A receiver that types it into a terminal would run
 * one starting with '/' or '$' as a command, '!' is a harness composer's shell
 * escape, and a leading '-' reads as an option. None of the four may lead,
 * with or without whitespace in front.
 */
export function directTextProblem(text) {
    if (text.trim() === "")
        return "訊息不能是空的。";
    if (/^\s*[/$!-]/.test(text)) {
        return "以 /、$、! 或 - 開頭會被當成指令。要跑指令請到終端機，要傳文字請在開頭加字。";
    }
    return null;
}
function feedArgs(command) {
    if (!HOME_ID.test(command.home))
        refuse(`malformed home id: ${command.home}`);
    if (!Number.isInteger(command.offset) || command.offset < 0)
        refuse("offset must be a non-negative integer");
    if (!SHA.test(command.sha))
        refuse("prefix hash must be 64 hex characters or '-'");
    const args = ["feed", command.home, String(command.offset), command.sha];
    const { closed } = command;
    if (closed === undefined)
        return args;
    if (!Number.isInteger(closed.offset) || closed.offset < 0)
        refuse("closed offset must be a non-negative integer");
    if (!SHA.test(closed.sha))
        refuse("closed prefix hash must be 64 hex characters or '-'");
    return [...args, String(closed.offset), closed.sha];
}
/** Turns an allowed command into the arguments to run; throws CommandRefused otherwise. */
export function invocationFor(command) {
    if (command.kind === "feed")
        return { args: feedArgs(command) };
    if (/[\r\n]/.test(command.record))
        refuse("an action record must be one line");
    return { args: ["deliver"], stdin: `${command.record}\n` };
}
/**
 * Why the aggregator's program cannot be started, or null when it can: it
 * must be a regular file (a symlink to one counts) with an execute bit.
 */
export function programProblem(root) {
    const program = path.join(root, AGGREGATOR_PROGRAM);
    let stat;
    try {
        stat = fs.statSync(program);
    }
    catch {
        return `沒有 ${AGGREGATOR_PROGRAM}`;
    }
    if (!stat.isFile())
        return `${AGGREGATOR_PROGRAM} 不是一般檔案`;
    return (stat.mode & 0o111) === 0 ? `${AGGREGATOR_PROGRAM} 不能執行` : null;
}
/** Builds the runner bound to one home and code root. */
export function commandRunner(config) {
    return (command, timeoutMs) => new Promise((resolve) => {
        let invocation;
        try {
            invocation = invocationFor(command);
        }
        catch (error) {
            resolve({ code: null, stdout: "", stderr: error.message });
            return;
        }
        const child = execFile(path.join(config.root, AGGREGATOR_PROGRAM), invocation.args, {
            env: { ...process.env, MYSHAPE_HOME: config.home },
            timeout: timeoutMs,
            maxBuffer: MAX_OUTPUT_BYTES,
            encoding: "utf8",
        }, (error, stdout, stderr) => {
            const code = error === null ? 0 : typeof error.code === "number" ? error.code : null;
            resolve({
                code,
                stdout,
                stderr: error !== null && code === null ? `${stderr}${error.message}` : stderr,
            });
        });
        if (child.stdin !== null) {
            // A program that exits without reading its stdin closes the pipe
            // (EPIPE); its exit code and output already say how the run went.
            child.stdin.on("error", () => undefined);
            child.stdin.end(invocation.stdin);
        }
    });
}
