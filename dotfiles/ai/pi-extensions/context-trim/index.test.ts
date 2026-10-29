import { expect, test } from "bun:test";
import contextTrim from "./index.ts";

function harness(percent: number | null) {
  const entries: any[] = [];
  let handler: any;
  contextTrim({ on: (_: string, fn: any) => { handler = fn; },
    appendEntry: (customType: string, data: any) => entries.push({ type: "custom", customType, data }) } as any);
  const ctx = { getContextUsage: () => ({ percent, tokens: 1, contextWindow: 200_000 }),
    sessionManager: { getBranch: () => entries } };
  return { entries, run: (messages: any[]) => handler({ messages: structuredClone(messages) }, ctx) };
}

const big = "HEAD" + "x".repeat(100_000) + "TAIL";
const messages = [
  { role: "user", content: [{ type: "text", text: "first" }, { type: "image", data: "AAAA", mimeType: "image/png" }], timestamp: 1 },
  { role: "assistant", content: [{ type: "toolCall", id: "b", name: "bash", arguments: { command: "ls" } },
    { type: "toolCall", id: "r", name: "read", arguments: { path: "/tmp/shot.png" } },
    { type: "toolCall", id: "f", name: "read", arguments: { path: "/tmp/file.ts" } }], timestamp: 2 },
  { role: "toolResult", toolCallId: "b", toolName: "bash", content: [{ type: "text", text: big }], timestamp: 3 },
  { role: "toolResult", toolCallId: "r", toolName: "read", content: [{ type: "text", text: "Read image" }, { type: "image", data: "AAAA", mimeType: "image/png" }], timestamp: 4 },
  { role: "toolResult", toolCallId: "f", toolName: "read", content: [{ type: "text", text: big }], timestamp: 5 },
  { role: "user", content: "second", timestamp: 6 },
  { role: "toolResult", toolCallId: "n", toolName: "bash", content: [{ type: "text", text: big }], timestamp: 7 },
  { role: "user", content: "third", timestamp: 8 },
];

test("below the trigger nothing changes and no cutoff is saved", async () => {
  const h = harness(40);
  expect(await h.run(messages)).toBeUndefined();
  expect(h.entries).toHaveLength(0);
});

test("over the trigger, output older than the last two user messages is trimmed and the cutoff persists", async () => {
  const h = harness(60);
  const out = (await h.run(messages)).messages;
  expect(h.entries).toEqual([{ type: "custom", customType: "context-trim", data: { cutoff: 6 } }]);
  expect(out[0].content[1]).toEqual({ type: "text", text: "[Old image removed from context.]" });
  const bash = out[2].content[0].text;
  expect(bash.startsWith("HEAD")).toBe(true);
  expect(bash.endsWith("TAIL")).toBe(true);
  expect(bash).toContain("bytes of old output removed from context");
  expect(out[3].content[1].text).toContain('reread "/tmp/shot.png"');
  expect(out[4].content[0].text).toBe(big);
  expect(out[6].content[0].text).toBe(big);
  expect(out[5]).toEqual(messages[5]);

  const later = harness(10);
  later.entries.push(...h.entries);
  expect((await later.run(messages)).messages).toEqual(out);
  expect(later.entries).toHaveLength(1);
});

test("the cutoff does not creep forward for small savings", async () => {
  const small = messages.map(m => m.role === "toolResult" ? { ...m, content: [{ type: "text", text: "short" }] } : m)
    .map(m => m.role === "user" && Array.isArray(m.content) ? { ...m, content: [m.content[0]] } : m);
  const h = harness(90);
  expect(await h.run(small)).toBeUndefined();
  expect(h.entries).toHaveLength(0);
});
