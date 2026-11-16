import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { CommandRefused, commandRunner, directTextProblem, invocationFor } from "./commands.js";
import type { AllowedCommand, Secondmate } from "./commands.js";

const KNOWN: Secondmate[] = [
  { id: "sm1", remote: false, home: "/homes/sm1" },
  { id: "far1", remote: true, home: "/srv/home" },
];
const SHA = "a".repeat(64);
const DELIVERY = "0123456789abcdef";

function refusedFor(command: AllowedCommand): string {
  try {
    invocationFor(command, KNOWN);
  } catch (error) {
    if (error instanceof CommandRefused) return error.message;
    throw error;
  }
  throw new Error("the command was allowed");
}

describe("read commands", () => {
  it("builds the three read shapes", () => {
    expect(invocationFor({ kind: "read-main", offset: 0, sha: "-" }, KNOWN)).toEqual({
      script: "fm-topic-board-read.sh",
      args: ["0", "-"],
    });
    expect(
      invocationFor({ kind: "read-local", secondmate: "sm1", offset: 12, sha: SHA }, KNOWN),
    ).toEqual({
      script: "fm-topic-board-read.sh",
      args: ["--in-home", "sm1", "12", SHA],
    });
    expect(
      invocationFor({ kind: "read-remote", secondmate: "far1", offset: 7, sha: SHA }, KNOWN),
    ).toEqual({
      script: "fm-on.sh",
      args: ["far1", "fm-topic-board-read.sh", "7", SHA],
    });
  });

  it("refuses bad offsets, hashes, and secondmates", () => {
    expect(refusedFor({ kind: "read-main", offset: -1, sha: "-" })).toContain("offset");
    expect(refusedFor({ kind: "read-main", offset: 1.5, sha: "-" })).toContain("offset");
    expect(refusedFor({ kind: "read-main", offset: 0, sha: "abc" })).toContain("hash");
    expect(refusedFor({ kind: "read-main", offset: 0, sha: `${SHA}0` })).toContain("hash");
    expect(refusedFor({ kind: "read-main", offset: 0, sha: "A".repeat(64) })).toContain("hash");
    expect(refusedFor({ kind: "read-local", secondmate: "nobody", offset: 0, sha: "-" })).toBe(
      "unknown secondmate: nobody",
    );
    expect(refusedFor({ kind: "read-local", secondmate: "far1", offset: 0, sha: "-" })).toBe(
      "secondmate far1 is remote",
    );
    expect(refusedFor({ kind: "read-remote", secondmate: "sm1", offset: 0, sha: "-" })).toBe(
      "secondmate sm1 is local",
    );
    expect(refusedFor({ kind: "read-remote", secondmate: "-x", offset: 0, sha: "-" })).toContain(
      "malformed secondmate id",
    );
    expect(refusedFor({ kind: "read-remote", secondmate: "a b", offset: 0, sha: "-" })).toContain(
      "malformed secondmate id",
    );
  });
});

describe("write commands", () => {
  it("builds a note with its body on stdin", () => {
    expect(
      invocationFor({ kind: "note", requestId: "tb-1:a.b_c", body: "hello\n" }, KNOWN),
    ).toEqual({
      script: "fm-inbox.sh",
      args: ["note", "--request-id", "tb-1:a.b_c", "-"],
      stdin: "hello\n",
    });
    expect(refusedFor({ kind: "note", requestId: ".hidden", body: "x" })).toContain("request id");
    expect(refusedFor({ kind: "note", requestId: "a/b", body: "x" })).toContain("request id");
    expect(refusedFor({ kind: "note", requestId: "x".repeat(129), body: "x" })).toContain(
      "request id",
    );
    expect(
      invocationFor({ kind: "note", requestId: "x".repeat(128), body: "x" }, KNOWN).script,
    ).toBe("fm-inbox.sh");
  });

  it("builds a direct send and a relay", () => {
    expect(invocationFor({ kind: "send", task: "ship-a", text: "look at CI" }, KNOWN)).toEqual({
      script: "fm-send.sh",
      args: ["ship-a", "look at CI"],
    });
    expect(
      invocationFor(
        { kind: "relay", secondmate: "far1", deliveryId: DELIVERY, text: "轉給 w：hi" },
        KNOWN,
      ),
    ).toEqual({
      script: "fm-send.sh",
      args: ["far1", "--fire-and-forget", DELIVERY, "轉給 w：hi"],
    });
    expect(
      invocationFor({ kind: "relay", secondmate: "sm1", deliveryId: DELIVERY, text: "x" }, KNOWN)
        .args[0],
    ).toBe("sm1");
    expect(refusedFor({ kind: "send", task: "-task", text: "x" })).toContain("malformed task id");
    expect(
      refusedFor({ kind: "relay", secondmate: "nobody", deliveryId: DELIVERY, text: "x" }),
    ).toBe("unknown secondmate: nobody");
    expect(
      refusedFor({ kind: "relay", secondmate: "far1", deliveryId: "0123456789ABCDEF", text: "x" }),
    ).toContain("16 lowercase hex");
    expect(
      refusedFor({ kind: "relay", secondmate: "far1", deliveryId: `${DELIVERY}0`, text: "x" }),
    ).toContain("16 lowercase hex");
    expect(
      refusedFor({
        kind: "relay",
        secondmate: "far1",
        deliveryId: `x${DELIVERY.slice(1)}`,
        text: "x",
      }),
    ).toContain("16 lowercase hex");
  });

  it("refuses text fm-send.sh would treat as a command or an option", () => {
    for (const text of ["/compact", "$skill", "-x", "--key", "", "   "]) {
      expect(directTextProblem(text)).not.toBeNull();
      expect(refusedFor({ kind: "send", task: "t", text })).not.toBe("");
      expect(
        refusedFor({ kind: "relay", secondmate: "far1", deliveryId: DELIVERY, text }),
      ).not.toBe("");
    }
    expect(directTextProblem("")).toBe("訊息不能是空的。");
    expect(directTextProblem("/x")).toContain("會被當成指令");
    for (const text of [
      " /exit",
      "\t$HOME",
      "\n-x",
      "!rm -rf x",
      "  !ls",
      "\u00a0/clear",
      "\u3000/clear",
    ]) {
      expect(`${JSON.stringify(text)} ${directTextProblem(text)}`).toContain("會被當成指令");
    }
    expect(directTextProblem("看一下 /tmp 和 $HOME，然後回報！")).toBeNull();
    expect(directTextProblem("a /b $c -d")).toBeNull();
  });

  it("builds the three answer shapes with a newline-terminated line", () => {
    const line = "call-1\tyes\tyes\trelease";
    expect(invocationFor({ kind: "answer", placement: "main", line }, KNOWN)).toEqual({
      script: "fm-captain-hold.sh",
      args: ["answers", "--source", "topic-board"],
      stdin: `${line}\n`,
    });
    expect(
      invocationFor({ kind: "answer", placement: "local", secondmate: "sm1", line }, KNOWN),
    ).toEqual({
      script: "fm-topic.sh",
      args: ["--in-home", "sm1", "answers"],
      stdin: `${line}\n`,
    });
    expect(
      invocationFor({ kind: "answer", placement: "remote", secondmate: "far1", line }, KNOWN),
    ).toEqual({
      script: "fm-on.sh",
      args: ["--stdin", "far1", "fm-captain-hold.sh", "answers", "--source", "topic-board"],
      stdin: `${line}\n`,
    });
    expect(
      invocationFor({ kind: "answer", placement: "main", line: "t\ta\t\tdone" }, KNOWN).stdin,
    ).toBe("t\ta\t\tdone\n");
  });

  it("refuses malformed answer lines and misplaced secondmates", () => {
    const answer = (line: string): string =>
      refusedFor({ kind: "answer", placement: "main", line });
    expect(answer("t\ta\tl")).toContain("four tab-separated");
    expect(answer("t\ta\tl\tdone\textra")).toContain("four tab-separated");
    expect(answer("t\ta\nb\tl\tdone")).toContain("four tab-separated");
    expect(answer("t\ta\rb\tl\tdone")).toContain("four tab-separated");
    expect(answer("t\t\tl\tdone")).toBe("malformed answer line");
    expect(answer("-t\ta\tl\tdone")).toBe("malformed answer line");
    expect(answer("t\ta\tl\tmaybe")).toBe("malformed answer line");
    expect(answer("t\ta\tl\t")).toBe("malformed answer line");
    expect(
      refusedFor({ kind: "answer", placement: "local", secondmate: "far1", line: "t\ta\tl\tdone" }),
    ).toBe("secondmate far1 is remote");
    expect(
      refusedFor({ kind: "answer", placement: "remote", secondmate: "sm1", line: "t\ta\tl\tdone" }),
    ).toBe("secondmate sm1 is local");
    expect(refusedFor({ kind: "answer", placement: "local", line: "t\ta\tl\tdone" })).toContain(
      "malformed secondmate id",
    );
  });

  it("builds the three tag shapes", () => {
    expect(
      invocationFor({ kind: "tag", placement: "main", task: "t1", topic: "billing" }, KNOWN),
    ).toEqual({
      script: "fm-topic.sh",
      args: ["tag", "t1", "billing"],
    });
    expect(
      invocationFor(
        { kind: "tag", placement: "local", secondmate: "sm1", task: "t1", topic: "billing" },
        KNOWN,
      ),
    ).toEqual({
      script: "fm-topic.sh",
      args: ["--in-home", "sm1", "tag", "t1", "billing"],
    });
    expect(
      invocationFor(
        { kind: "tag", placement: "remote", secondmate: "far1", task: "t1", topic: "billing" },
        KNOWN,
      ),
    ).toEqual({
      script: "fm-on.sh",
      args: ["far1", "fm-topic.sh", "tag", "t1", "billing"],
    });
    expect(refusedFor({ kind: "tag", placement: "main", task: "--from", topic: "x" })).toContain(
      "malformed task id",
    );
    expect(refusedFor({ kind: "tag", placement: "main", task: "t", topic: "a b" })).toContain(
      "malformed topic id",
    );
    expect(
      refusedFor({ kind: "tag", placement: "remote", secondmate: "sm1", task: "t", topic: "x" }),
    ).toBe("secondmate sm1 is local");
  });
});

describe("commandRunner", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tb-commands-"));
  fs.mkdirSync(path.join(root, "bin"));
  const script = (name: string, body: string): void => {
    fs.writeFileSync(path.join(root, "bin", name), `#!/usr/bin/env bash\n${body}\n`, {
      mode: 0o755,
    });
  };
  const config = { home: "/the/main/home", root, commit: "c", port: 1, state: "/s", data: "/d" };
  const run = commandRunner(config);
  afterAll(() => fs.rmSync(root, { recursive: true, force: true }));

  it("runs the script from the code root with FM_HOME, the arguments, and stdin", async () => {
    script("fm-inbox.sh", 'printf "%s|" "$FM_HOME" "$@"; cat');
    const result = await run({ kind: "note", requestId: "r1", body: "the body" }, KNOWN, 5000);
    expect(result).toEqual({
      code: 0,
      stdout: "/the/main/home|note|--request-id|r1|-|the body",
      stderr: "",
    });
  });

  it("returns the exit code and stderr of a failing script", async () => {
    script("fm-send.sh", 'echo "no such task" >&2; exit 3');
    const result = await run({ kind: "send", task: "t", text: "hi" }, KNOWN, 5000);
    expect(result).toEqual({ code: 3, stdout: "", stderr: "no such task\n" });
  });

  it("passes text as one argument, never through a shell", async () => {
    script("fm-send.sh", 'printf "%s\n" "$#" "$2"');
    const text = 'a; rm -rf / $(id) `id` "q"';
    const result = await run({ kind: "send", task: "t", text }, KNOWN, 5000);
    expect(result.stdout).toBe(`2\n${text}\n`);
  });

  it("reports a refused command without running anything", async () => {
    script("fm-send.sh", "touch ran");
    const result = await run({ kind: "send", task: "t", text: "/compact" }, KNOWN, 5000);
    expect(result.code).toBeNull();
    expect(result.stderr).toContain("會被當成指令");
    expect(fs.existsSync(path.join(root, "ran"))).toBe(false);
  });

  it("gives a null code when the script is missing or times out", async () => {
    const missing = await run(
      { kind: "tag", placement: "main", task: "t", topic: "x" },
      KNOWN,
      5000,
    );
    expect(missing.code).toBeNull();
    expect(missing.stderr).not.toBe("");
    script("fm-topic.sh", "sleep 5");
    const slow = await run({ kind: "tag", placement: "main", task: "t", topic: "x" }, KNOWN, 200);
    expect(slow.code).toBeNull();
  });
});
