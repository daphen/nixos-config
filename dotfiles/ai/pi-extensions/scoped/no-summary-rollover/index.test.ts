import { describe, expect, test, spyOn } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import noSummaryRollover from "./index.ts";

async function pruning(run: (h: any) => Promise<void>) {
  const dir = mkdtempSync(join(tmpdir(), "jev-unit-"));
  mkdirSync(join(dir, ".git"));
  writeFileSync(join(dir, "session.jsonl"), "synthetic saved session");
  const messages: any[] = [{ role: "user", content: "TASK " + "u".repeat(480_000), timestamp: 1 }];
  for (let i = 0; i < 6; i++) {
    const path = join(dir, `${i}.txt`);
    writeFileSync(path, "fixture");
    messages.push({ role: "assistant", content: [{ type: "toolCall", id: `t${i}`, name: "read", arguments: { path } }], timestamp: 2 + i });
    messages.push({ role: "toolResult", toolCallId: `t${i}`, toolName: "read", content: [{ type: "text", text: `READ_${i} ` + "x".repeat(20_000) }], details: { sentinel: "preserve" }, isError: false, timestamp: 10 + i });
  }
  const entries: any[] = messages.map((message, i) => ({ type: "message", id: `m${i}`, message }));
  const events: any = {}, commands: any = {}, requests: any[] = [];
  let branch = entries, session = "original", lookups = 0;
  const ctx = { cwd: dir, model: { contextWindow: 200_000 }, signal: new AbortController().signal,
    ui: { notify() {} }, sessionManager: { getEntries: () => entries, getBranch: () => branch,
      getSessionId: () => session, getSessionFile: () => join(dir, "session.jsonl") } };
  const fetch = spyOn(globalThis, "fetch").mockImplementation((async (_url, init) => {
    const body = JSON.parse(init!.body as string); requests.push(body);
    return Response.json({ model: "test-jev", usage: { input_tokens: 1, output_tokens: 2 },
      answers: Object.fromEntries(Object.keys(body.questions).map(key => [key, { noul: 0.01 }])) });
  }) as typeof globalThis.fetch);
  noSummaryRollover({ on: (name: string, fn: any) => { events[name] = fn; },
    registerCommand: (name: string, fn: any) => { commands[name] = fn; },
    getAllTools: () => [{ name: "read", sourceInfo: { source: "builtin" } }],
    exec: async () => { lookups++; return { code: 0, killed: false, stdout: "synthetic-key" }; },
    appendEntry: (customType: string, data: any) => {
      const entry = { type: "custom", id: `c${entries.length}`, customType, data };
      entries.push(entry); if (branch !== entries) branch.push(entry);
    },
  } as any);
  try {
    await run({ ctx, entries, messages, events, requests, fetch, lookups: () => lookups,
      command: (mode: string) => commands["jev-pruning"].handler(mode, ctx),
      context: () => events.context({ messages: structuredClone(messages) }, ctx),
      branch: (value: any[]) => { branch = value; }, session: (value: string) => { session = value; } });
  } finally { fetch.mockRestore(); rmSync(dir, { recursive: true, force: true }); }
}

test("off has no side effects; shadow stays intact and never becomes a live decision", async () => pruning(async h => {
  expect(await h.context()).toBeUndefined();
  expect(h.lookups()).toBe(0); expect(h.requests).toHaveLength(0);
  await h.command("shadow");
  expect(await h.context()).toBeUndefined();
  expect(h.lookups()).toBe(0);
  await h.command("shadow personal Cockpit composer overlap");
  expect((await h.context()).messages).toEqual(h.messages);
  expect(JSON.stringify(h.requests)).not.toContain("READ_0");
  const calls = h.requests.length;
  await h.command("on");
  const filtered = (await h.context()).messages;
  expect(h.requests.length).toBeGreaterThan(calls);
  expect(JSON.stringify(h.requests.slice(calls))).toContain("READ_0");
  expect(filtered[2].content[0].text).toContain("Jev omitted");
  expect(filtered[2].details).toEqual(h.messages[2].details);
  expect(filtered[1]).toEqual(h.messages[1]);
  expect(filtered.slice(-6)).toEqual(h.messages.slice(-6));
  expect(h.entries[2].message.content[0].text).toContain("READ_0");
  const after = h.requests.length; await h.context(); expect(h.requests.length).toBe(after);
}));

test("shadow pairs call/result scores against approved chronological metadata, without sending outputs", async () => pruning(async h => {
  h.fetch.mockImplementation(async (_url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string); h.requests.push(body);
    return Response.json({ model: "test-jev", answers: Object.fromEntries(Object.keys(body.questions).map(key =>
      [key, { noul: key === "call_m2" ? 0.15 : key === "result_m2" ? 0.12 : 0.72 }])) });
  });
  await h.command("shadow personal Cockpit composer overlap");
  const result = await h.context();
  expect(result.messages).toEqual(h.messages);
  const body = h.requests[0];
  expect(body.state.history.map((read: any) => read.id)).toEqual(["m2", "m4", "m6"]);
  expect(body.state.history[0].result).toContain("bytes (omitted)");
  expect(body.state.task).toBe("personal Cockpit composer overlap");
  expect(JSON.stringify(h.requests)).not.toContain("TASK u");
  expect(Object.keys(body.questions)).toEqual(["call_m2", "result_m2", "call_m4", "result_m4", "call_m6", "result_m6"]);
  expect(JSON.stringify(h.requests)).not.toContain("READ_0");
  expect(JSON.stringify(h.requests)).not.toContain("x".repeat(100));
  const pass = h.entries.findLast((e: any) => e.data?.kind === "pass").data;
  expect(pass.selections[0]).toMatchObject({ entry: "m2", callKeep: 0.15, keep: 0.12 });
  expect(pass.bytes).toBeGreaterThan(20_000);
  expect(h.entries[2].message.content[0].text).toContain("READ_0");
}));

test("missing one paired shadow score retains the original", async () => pruning(async h => {
  h.fetch.mockImplementation(async (_url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string); h.requests.push(body);
    return Response.json({ answers: Object.fromEntries(Object.keys(body.questions)
      .filter(key => key !== "call_m2").map(key => [key, { noul: 0.01 }])) });
  });
  await h.command("shadow personal Cockpit composer overlap");
  expect((await h.context()).messages).toEqual(h.messages);
  const pass = h.entries.findLast((e: any) => e.data?.kind === "pass").data;
  expect(pass.outcome).toBe("unavailable");
  expect(pass.selections).toEqual([]);
}));

test("compact immediately shortens outgoing tool pairs while retaining mutations and recent work", async () => pruning(async h => {
  h.ctx.model.contextWindow = 1_050_000;
  h.messages[3].content[0].name = "bash";
  h.messages[3].content[0].arguments = { command: "WORK_VM_SECRET command" };
  h.messages[4].toolName = "bash";
  h.messages[5].content[0].name = "edit";
  h.messages[5].content[0].arguments = { path: h.messages[1].content[0].arguments.path, oldText: "SECRET" };
  h.messages[6].toolName = "edit";
  h.fetch.mockImplementation(async (_url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string); h.requests.push(body);
    return Response.json({ model: "test-jev", answers: Object.fromEntries(Object.keys(body.questions).map(key =>
      [key, { noul: key === "call_m4" ? 0.9 : 0.01 }])) });
  });
  await h.command("compact personal Cockpit implementation");
  const result = (await h.context()).messages;
  expect(result.length).toBe(h.messages.length - 2);
  expect(result.some((m: any) => m.role === "toolResult" && m.toolCallId === "t0")).toBe(false);
  expect(result.some((m: any) => m.role === "assistant" && m.content.some((b: any) => b.id === "t0"))).toBe(false);
  expect(result.find((m: any) => m.toolCallId === "t1").content[0].text).toContain("Jev omitted old bash output");
  expect(result.find((m: any) => m.toolCallId === "t2").content[0].text).toContain("do not rerun mutations");
  expect(result.find((m: any) => m.role === "assistant" && m.content.some((b: any) => b.id === "t2"))).toEqual(h.messages[5]);
  expect(result.slice(-6)).toEqual(h.messages.slice(-6));
  expect(h.entries[2].message.content[0].text).toContain("READ_0");
  expect(h.entries[4].message.content[0].text).toContain("READ_1");
  expect(h.requests).toHaveLength(1);
  expect(h.requests[0].state.history.map((x: any) => x.tool)).toEqual(["read", "bash", "edit"]);
  expect(JSON.stringify(h.requests)).not.toContain("WORK_VM_SECRET");
  expect(JSON.stringify(h.requests)).not.toContain("READ_0");
  expect(JSON.stringify(result).length).toBeLessThan(JSON.stringify(h.messages).length - 40_000);
  const after = h.requests.length; await h.context(); expect(h.requests.length).toBe(after);
}));

test("compact keeps a read call linked to signed reasoning and abbreviates only its result", async () => pruning(async h => {
  h.messages[1].content.unshift({ type: "thinking", thinking: "reason", thinkingSignature: "opaque" });
  await h.command("compact personal Cockpit implementation");
  const result = (await h.context()).messages;
  expect(result).toHaveLength(h.messages.length - 4);
  expect(result[1]).toEqual(h.messages[1]);
  expect(result[2].content[0].text).toContain("Jev omitted old read output");
  expect(result.slice(-6)).toEqual(h.messages.slice(-6));
}));

test("compact retains a read whose outgoing call changed after scoring", async () => pruning(async h => {
  await h.command("compact personal Cockpit implementation");
  await h.context();
  h.messages[1].content[0].arguments.path = h.messages[3].content[0].arguments.path;
  const result = (await h.context()).messages;
  expect(result.find((m: any) => m.toolCallId === "t0")?.content[0].text).toContain("READ_0");
  expect(result.find((m: any) => m.role === "assistant" && m.content.some((b: any) => b.id === "t0"))).toBeDefined();
}));

test("off is session-wide, fork consent is absent, and selections are branch-local", async () => pruning(async h => {
  await h.command("on"); await h.context();
  const earlier = h.entries.slice();
  await h.command("off"); h.branch(earlier);
  expect(await h.context()).toBeUndefined();
  await h.command("on"); h.session("fork");
  expect(await h.context()).toBeUndefined();
  h.session("original"); h.branch(earlier.filter((e: any) => e.type === "message"));
  const count = h.requests.length; await h.context(); expect(h.requests.length).toBeGreaterThan(count);
}));

test("changed result content is retained and a new goal expires old selections", async () => pruning(async h => {
  await h.command("on"); await h.context();
  h.messages[2].content[0].text = "CHANGED " + "y".repeat(20_000);
  expect((await h.context()).messages[2]).toEqual(h.messages[2]);
  h.messages.push({ role: "user", content: "A different task", timestamp: 100 });
  h.entries.push({ type: "message", id: "new-user", message: h.messages.at(-1) });
  h.fetch.mockImplementation(async () => Response.json({ answers: {} }));
  expect((await h.context()).messages).toEqual(h.messages);
}));

test("an incomplete batch does not count toward the three protected completed exchanges", async () => pruning(async h => {
  h.messages[11].content.push({ type: "toolCall", id: "missing", name: "read", arguments: { path: "pending.txt" } });
  await h.command("on");
  const filtered = (await h.context()).messages;
  expect(filtered[2].content[0].text).toContain("Jev omitted");
  expect(filtered[6]).toEqual(h.messages[6]);
  expect(filtered.slice(-6)).toEqual(h.messages.slice(-6));
}));

test("automatic split checkpoint uses selections without changing native boundaries", async () => pruning(async h => {
  await h.command("on"); await h.context();
  const event = compactEvent("overflow", h.messages.slice(0, 1));
  event.branchEntries = h.entries;
  event.preparation.turnPrefixMessages = h.messages.slice(1, 3);
  event.preparation.isSplitTurn = true;
  const calls = h.requests.length;
  const result = h.events.session_before_compact(event, h.ctx).compaction;
  expect(result.summary).toContain("Jev omitted"); expect(result.summary).not.toContain("READ_0");
  expect(result.firstKeptEntryId).toBe("kept-entry"); expect(result.tokensBefore).toBe(123_456);
  expect(result.details.readFiles).toEqual(["read.ts"]);
  expect(h.requests.length).toBe(calls);
  expect(h.events.session_before_compact({ ...event, reason: "manual" }, h.ctx)).toBeUndefined();
}));

function registeredHandler() {
  let handler: ((event: any, ctx?: any) => any) | undefined;
  noSummaryRollover({
    registerCommand() {},
    on(event: string, value: (event: any) => any) {
      if (event === "session_before_compact") handler = value;
    },
  } as any);
  expect(handler).toBeDefined();
  return (event: any) => handler!(event, { sessionManager: { getEntries: () => [], getSessionFile: () => undefined } });
}

function compactEvent(reason = "threshold", messages: any[] = [], previousSummary?: string) {
  return {
    type: "session_before_compact",
    reason,
    willRetry: false,
    signal: new AbortController().signal,
    branchEntries: [],
    preparation: {
      firstKeptEntryId: "kept-entry",
      tokensBefore: 123_456,
      messagesToSummarize: messages,
      turnPrefixMessages: [] as any[],
      isSplitTurn: false,
      previousSummary,
      fileOps: {
        read: new Set(["read.ts", "changed.ts"]),
        written: new Set(["created.ts"]),
        edited: new Set(["changed.ts"]),
      },
      settings: { enabled: true, reserveTokens: 16_384, keepRecentTokens: 20_000 },
    },
  };
}

const user = (content: unknown) => ({ role: "user", content, timestamp: 1 });
const assistant = (text: string) => ({
  role: "assistant",
  content: [{ type: "text", text }],
  api: "openai-responses",
  provider: "openai",
  model: "test",
  usage: {},
  stopReason: "stop",
  timestamp: 2,
});

describe("no-summary rollover extension", () => {
  test("registers a threshold compaction that preserves Pi's boundary", () => {
    const result = registeredHandler()(compactEvent("threshold", [
      user("Keep the exact socket stable."),
      user([{ type: "text", text: "Inspect this" }, { type: "image", mimeType: "image/png", data: "ignored" }]),
      assistant("ordinary prose\n⟢ Verified the public behavior."),
    ], "Older checkpoint"));

    expect(result.compaction.firstKeptEntryId).toBe("kept-entry");
    expect(result.compaction.tokensBefore).toBe(123_456);
    expect(result.compaction.usage).toBeUndefined();
    expect(result.compaction.summary).toContain("Keep the exact socket stable.");
    expect(result.compaction.summary).toContain("[image omitted: image/png]");
    expect(result.compaction.summary).toContain("⟢ Verified the public behavior.");
    expect(result.compaction.summary).toContain("Older checkpoint");
    expect(result.compaction.details).toEqual({
      strategy: "deterministic-auto-v3",
      readFiles: ["read.ts"],
      modifiedFiles: ["changed.ts", "created.ts"],
    });
  });

  test("leaves explicit manual compaction with Pi", () => {
    expect(registeredHandler()(compactEvent("manual"))).toBeUndefined();
  });

  test("preserves split-turn continuity and includes only completed tool batches", () => {
    const split = compactEvent("overflow", [user("Keep the older deployment constraint.")]);
    split.preparation.isSplitTurn = true;
    split.preparation.turnPrefixMessages = [
      user("Continue validating PR 97422 without restarting its worker."),
      {
        ...assistant("Checking the current state."),
        content: [
          { type: "text", text: "Checking the current state." },
          { type: "toolCall", id: "call-1", name: "read", arguments: { path: "state.json" } },
        ],
      },
      { role: "toolResult", toolCallId: "call-1", toolName: "read", content: [{ type: "text", text: "review pending" }], timestamp: 3 },
      {
        ...assistant("Next operation started."),
        content: [{ type: "toolCall", id: "call-2", name: "write", arguments: { path: "unsafe" } }],
      },
    ];

    const result = registeredHandler()(split);
    expect(result.compaction.firstKeptEntryId).toBe("kept-entry");
    expect(result.compaction.tokensBefore).toBe(123_456);
    expect(result.compaction.usage).toBeUndefined();
    expect(result.compaction.details.strategy).toBe("deterministic-auto-v3");
    expect(result.compaction.summary).toContain("Keep the older deployment constraint.");
    expect(result.compaction.summary).toContain("Continue validating PR 97422");
    expect(result.compaction.summary).toContain("tool read completed: review pending");
    expect(result.compaction.summary).not.toContain("tool write completed");
  });

  test("falls back when Pi has no context to replace", () => {
    expect(registeredHandler()(compactEvent())).toBeUndefined();
  });

  test("is UTF-8 safe, bounded, and synchronous", () => {
    const huge = "🦄".repeat(20_000);
    const start = performance.now();
    const result = registeredHandler()(compactEvent("threshold", [user(huge)], huge));
    const elapsed = performance.now() - start;
    expect(Buffer.byteLength(result.compaction.summary, "utf8")).toBeLessThanOrEqual(20_000);
    expect(result.compaction.summary).not.toContain("�");
    expect(elapsed).toBeLessThan(1_000);
  });
});
