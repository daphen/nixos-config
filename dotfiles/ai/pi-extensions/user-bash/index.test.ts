import { describe, expect, mock, test } from "bun:test";

mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, String: () => ({}) } }));
const { USER_BASH_APPROVAL_ENTRY, USER_BASH_TITLE, runUserBash, default: userBashExtension } = await import("./index.ts");

const request = {
  command: "printf exact",
  reason: "the role cannot perform this operation",
  cwd: "/repo/ticket",
  host: "work-vm",
};

function text(result: any): string {
  return result.content[0].text;
}

describe("runUserBash", () => {
  test("does not invoke the runner before the human approves", async () => {
    let ran = false;
    let release!: (approved: boolean) => void;
    const approval = new Promise<boolean>(resolve => { release = resolve; });
    const pending = runUserBash(request, async (title, message) => {
      expect(title).toBe(USER_BASH_TITLE);
      expect(JSON.parse(message)).toEqual(request);
      return approval;
    }, async () => { ran = true; return { output: "", exitCode: 0 }; });

    await Promise.resolve();
    expect(ran).toBe(false);
    release(true);
    await pending;
    expect(ran).toBe(true);
  });

  test("decline is inert", async () => {
    let calls = 0;
    const result = await runUserBash(request, async () => false, async () => {
      calls++;
      return { output: "should not run", exitCode: 0 };
    }, undefined, () => { calls++; });
    expect(calls).toBe(0);
    expect(text(result)).toContain("declined");
  });

  test("records durable approval before running the exact command once", async () => {
    const events: unknown[][] = [];
    const result = await runUserBash(request, async () => true, async (command, cwd) => {
      events.push(["run", command, cwd]);
      return { output: "exact output\n", exitCode: 0 };
    }, undefined, approval => events.push(["approval", approval]));
    expect(events).toEqual([
      ["approval", { ...request, decision: "approved" }],
      ["run", request.command, request.cwd],
    ]);
    expect(text(result)).toBe("exact output\n\nCommand exited with code 0");
  });

  test("returns output and status as an error for a failed command", async () => {
    await expect(runUserBash(request, async () => true, async () => ({
      output: "permission denied\n",
      exitCode: 126,
    }))).rejects.toThrow("permission denied\n\nCommand exited with code 126");
  });

  test("passes cancellation to the runner", async () => {
    const controller = new AbortController();
    let received: AbortSignal | undefined;
    await runUserBash(request, async () => true, async (_command, _cwd, signal) => {
      received = signal;
      return { output: "", exitCode: 0 };
    }, controller.signal);
    expect(received).toBe(controller.signal);
  });

  test("registers the durable approval entry from the tool execution", async () => {
    let tool: any;
    const entries: unknown[][] = [];
    userBashExtension({
      registerTool: (value: any) => { tool = value; },
      on: () => {},
      appendEntry: (...args: unknown[]) => { entries.push(args); },
    } as any);
    const ctx = { cwd: request.cwd, ui: { confirm: async () => true } } as any;
    const controller = new AbortController();
    controller.abort();

    await expect(tool.execute("call", request, controller.signal, undefined, ctx)).rejects.toThrow();
    expect(entries).toEqual([[USER_BASH_APPROVAL_ENTRY, {
      ...request,
      host: expect.any(String),
      decision: "approved",
    }]]);
  });

  test("allows only one command card per user turn", async () => {
    let tool: any;
    let onInput: (() => void) | undefined;
    userBashExtension({
      registerTool: (value: any) => { tool = value; },
      on: (event: string, handler: () => void) => { if (event === "input") onInput = handler; },
    } as any);
    const ctx = { cwd: request.cwd, ui: { confirm: async () => false } } as any;
    const execute = () => tool.execute("call", request, new AbortController().signal, undefined, ctx);

    await execute();
    await expect(execute()).rejects.toThrow("already handed to the user this turn");
    onInput?.();
    await expect(execute()).resolves.toBeDefined();
  });
});
