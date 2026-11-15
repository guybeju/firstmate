// The only external commands the board service may run. The list is fixed
// here, never read from configuration. Every command is built as an argument
// array for execFile (no shell), runs a script from the code root's bin/, and
// gets FM_HOME set to the main home.
import { execFile } from "node:child_process";
import path from "node:path";
const ID = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/;
const SHA = /^(-|[0-9a-f]{64})$/;
const MAX_OUTPUT_BYTES = 4 * 1024 * 1024;
export class CommandRefused extends Error {
}
function refuse(reason) {
    throw new CommandRefused(reason);
}
function readArgs(command) {
    if (!Number.isInteger(command.offset) || command.offset < 0)
        refuse("offset must be a non-negative integer");
    if (!SHA.test(command.sha))
        refuse("prefix hash must be 64 hex characters or '-'");
    return [String(command.offset), command.sha];
}
/** Checks that `id` is a registered secondmate of the expected placement. */
function secondmateArg(id, remote, known) {
    if (!ID.test(id))
        refuse(`malformed secondmate id: ${id}`);
    const found = known.find((entry) => entry.id === id);
    if (found === undefined)
        refuse(`unknown secondmate: ${id}`);
    if (found.remote !== remote)
        refuse(`secondmate ${id} is ${found.remote ? "remote" : "local"}`);
    return id;
}
/** Turns an allowed command into the script and arguments to run; throws CommandRefused otherwise. */
export function invocationFor(command, known) {
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
                args: [secondmateArg(command.secondmate, true, known), "fm-topic-board-read.sh", ...readArgs(command)],
            };
    }
}
/** Builds the runner bound to one home and code root. */
export function commandRunner(config) {
    return (command, known, timeoutMs) => new Promise((resolve) => {
        let invocation;
        try {
            invocation = invocationFor(command, known);
        }
        catch (error) {
            resolve({ code: null, stdout: "", stderr: error.message });
            return;
        }
        const child = execFile(path.join(config.root, "bin", invocation.script), invocation.args, {
            env: { ...process.env, FM_HOME: config.home },
            timeout: timeoutMs,
            maxBuffer: MAX_OUTPUT_BYTES,
            encoding: "utf8",
        }, (error, stdout, stderr) => {
            const code = error === null ? 0 : typeof error.code === "number" ? error.code : null;
            resolve({ code, stdout, stderr: error !== null && code === null ? `${stderr}${error.message}` : stderr });
        });
        child.stdin?.end(invocation.stdin ?? "");
    });
}
