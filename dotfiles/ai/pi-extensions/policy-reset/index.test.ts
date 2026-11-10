import { expect, test } from "bun:test";
import install from "./index.ts";

function harness() {
  const handlers: Record<string, Function> = {};
  const notes: string[] = [];
  install({ on(name: string, fn: Function) { handlers[name] = fn; } } as any);
  const settle = (messages: any[], outcome = "error") =>
    handlers.agent_before_settle({ outcome, context: { contextMessages: messages } }, { ui: { notify: (m: string) => notes.push(m) } });
  return { handlers, notes, settle };
}

const blocked = { role: "assistant", content: [], stopReason: "error",
  errorMessage: "This request was blocked as it seems to violate Anthropic's Terms of Service restrictions" };
const history = [
  { role: "compactionSummary", summary: "older work" },
  { role: "user", content: "research pixel art" },
  { role: "toolResult", content: [{ type: "text", text: "FETCHED PAGE BODY" }] },
  { role: "assistant", content: [{ type: "text", text: "Found tools.\n⟢ Sprite Fusion fits best." }] },
  { role: "user", content: [{ type: "text", text: "My computer is lagging?" }] },
  blocked,
];

test("a usage-filter refusal resets context to requests and outcomes and retries once", () => {
  const { settle, handlers, notes } = harness();
  const result = settle(history);
  expect(result.continue).toBe(true);
  const [entry] = result.entries;
  expect(entry.type).toBe("compaction");
  expect(entry.firstKeptEntryId).toBeNull();
  expect(entry.summary).toContain("older work");
  expect(entry.summary).toContain("⟢ Sprite Fusion fits best.");
  expect(entry.summary).toContain("Answer this now: My computer is lagging?");
  expect(entry.summary).not.toContain("FETCHED PAGE BODY");

  expect(settle(history)).toBeUndefined();
  expect(notes.length).toBe(1);
  handlers.input();
  expect(settle(history)?.continue).toBe(true);
});

test("other errors and normal endings are left alone", () => {
  const { settle } = harness();
  expect(settle([{ role: "user", content: "hi" }, { ...blocked, errorMessage: "overloaded" }])).toBeUndefined();
  expect(settle([{ role: "user", content: "hi" }, { role: "assistant", content: [] }], "completed")).toBeUndefined();
});
