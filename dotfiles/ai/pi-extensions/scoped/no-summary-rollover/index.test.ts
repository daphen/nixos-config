import { describe, expect, test } from "bun:test";
import noSummaryRollover from "./index.ts";

function registeredHandler() {
  let handler: ((event: any) => any) | undefined;
  noSummaryRollover({
    on(event: string, value: (event: any) => any) {
      if (event === "session_before_compact") handler = value;
    },
  } as any);
  expect(handler).toBeDefined();
  return handler!;
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
