import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// A usage-filter refusal is a verdict on the whole resent context, so every retry fails
// the same way. Replace the context with requests and outcomes only (tool output is
// where fetched pages live) and answer the blocked request once more.
const BLOCKED = /request was blocked as it seems to violate/i;
const BUDGET = 24_000;

type Part = { type: string; text?: string };
const text = (content: unknown) =>
  typeof content === "string" ? content : Array.isArray(content)
    ? (content as Part[]).filter((p) => p.type === "text").map((p) => p.text ?? "").join("\n") : "";

function newest(lines: string[], budget: number) {
  const kept: string[] = [];
  let used = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].length > 1_500 ? lines[i].slice(0, 1_500) + "…" : lines[i];
    if (used + line.length > budget) break;
    kept.unshift(line);
    used += line.length;
  }
  return kept.join("\n");
}

export default function policyReset(pi: ExtensionAPI) {
  let resetPending = false;
  pi.on("input", () => { resetPending = false; });
  pi.on("agent_before_settle", (event, ctx) => {
    const messages = event.context.contextMessages as any[];
    const last = messages.at(-1);
    if (event.outcome !== "error" || last?.role !== "assistant" || !BLOCKED.test(last.errorMessage ?? "")) return;
    if (resetPending) {
      ctx.ui.notify("The usage filter refused the reset context too; start a fresh session.", "error");
      return;
    }
    const history: string[] = [];
    let earlier = "";
    let request = "";
    for (const m of messages) {
      if (m.role === "compactionSummary") earlier = m.summary ?? "";
      if (m.role === "user") { request = text(m.content); history.push(`- User: ${request}`); }
      if (m.role === "assistant") {
        const outcome = text(m.content).split("\n").findLast((l) => l.startsWith("⟢ "));
        if (outcome) history.push(`- Outcome: ${outcome}`);
      }
    }
    resetPending = true;
    const summary = [
      "# Context reset after a usage-filter refusal",
      "The provider refused the previous context, so tool output and fetched pages were dropped. Do not re-fetch the pages that were open. Verify files and state before acting.",
      `## Earlier summary\n${earlier.slice(0, 8_000) || "- none"}`,
      `## Recent requests and outcomes\n${newest(history, BUDGET) || "- none"}`,
      `## Unanswered request\nAnswer this now: ${request || "(none recorded)"}`,
    ].join("\n\n");
    return { entries: [{ type: "compaction", summary, firstKeptEntryId: null, details: { strategy: "policy-reset-v1" } }], continue: true };
  });
}
