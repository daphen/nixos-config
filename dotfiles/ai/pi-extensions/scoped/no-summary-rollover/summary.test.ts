import { expect, mock, test } from "bun:test";

const calls: any[] = [];
let reply: () => Promise<{ summary: string }> = async () => ({ summary: "MODEL SUMMARY" });
mock.module("@earendil-works/pi-coding-agent", () => ({
  compact: (preparation: any, model: any, apiKey: string) => { calls.push({ preparation, model, apiKey }); return reply(); },
}));
const { default: noSummaryRollover } = await import("./index.ts");

function harness(auth: any = { ok: true, apiKey: "key" }) {
  const entries: any[] = [], handlers: Record<string, any> = {}, notes: string[] = [];
  noSummaryRollover({
    on: (name: string, fn: any) => { if (name === "context") (handlers.context ??= []).push(fn); else handlers[name] = fn; },
    registerCommand() {},
    getAllTools: () => [],
    appendEntry: (customType: string, data: any) => entries.push({ type: "custom", id: `c${entries.length}`, customType, data }),
  } as any);
  const ctx = { cwd: "/", model: { id: "m", contextWindow: 200_000 }, ui: { notify: (text: string) => notes.push(text) },
    modelRegistry: { getApiKeyAndHeaders: async () => auth },
    sessionManager: { getEntries: () => entries, getBranch: () => entries, getSessionId: () => "s", getSessionFile: () => undefined } };
  const compactNow = (previousSummary?: string) => handlers.session_before_compact({
    reason: "threshold", branchEntries: entries,
    preparation: { firstKeptEntryId: "kept", tokensBefore: 180_000, isSplitTurn: false, previousSummary, turnPrefixMessages: [],
      messagesToSummarize: [{ role: "user", content: "build the thing", timestamp: 1 }],
      fileOps: { read: new Set(), written: new Set(), edited: new Set() }, settings: { keepRecentTokens: 20_000 } },
  }, ctx).compaction.summary as string;
  const context = async (summary: string) => {
    let messages: any[] = [{ role: "compactionSummary", summary, tokensBefore: 1, timestamp: 1 }, { role: "user", content: "next", timestamp: 2 }];
    for (const fn of handlers.context) messages = (await fn({ messages }, ctx))?.messages ?? messages;
    return messages;
  };
  return { entries, notes, compactNow, context };
}
const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test("the instant checkpoint is replaced in context by the model summary once it arrives", async () => {
  calls.length = 0; reply = async () => ({ summary: "MODEL SUMMARY" });
  const h = harness();
  const checkpoint = h.compactNow();
  expect(checkpoint).toStartWith("# Recovery checkpoint");
  expect((await h.context(checkpoint))[0].summary).toBe(checkpoint);
  await settle();
  expect(calls[0].apiKey).toBe("key");
  expect(calls[0].preparation.firstKeptEntryId).toBe("kept");
  const messages = await h.context(checkpoint);
  expect(messages[0].summary).toBe("MODEL SUMMARY");
  expect(messages[1].content).toBe("next");
});

test("the next rollover builds on the model summary, not the old checkpoint", async () => {
  calls.length = 0; reply = async () => ({ summary: "FIRST SUMMARY" });
  const h = harness();
  const first = h.compactNow();
  await settle();
  reply = async () => ({ summary: "SECOND SUMMARY" });
  const second = h.compactNow(first);
  expect(second).toContain("FIRST SUMMARY");
  await settle();
  expect(calls[1].preparation.previousSummary).toBe("FIRST SUMMARY");
  expect((await h.context(second))[0].summary).toBe("SECOND SUMMARY");
});

test("a failed summary keeps the checkpoint and says so", async () => {
  calls.length = 0; reply = async () => { throw new Error("overloaded"); };
  const h = harness();
  const checkpoint = h.compactNow();
  await settle(); await settle();
  expect((await h.context(checkpoint))[0].summary).toBe(checkpoint);
  expect(h.notes[0]).toContain("overloaded");
  const unauthorised = harness({ ok: false, error: "no key" });
  unauthorised.compactNow(); await settle();
  expect(unauthorised.entries).toHaveLength(0);
});
