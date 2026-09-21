import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("context", (event, ctx) => {
    const scores = JSON.parse(readFileSync(join(ctx.cwd, "scores.json"), "utf8"));
    const users = event.messages.flatMap((m, i) => m.role === "user" ? [i] : []);
    const recentStart = users.at(-2) ?? 0;
    const calls = new Map(event.messages.flatMap((m) => m.role === "assistant"
      ? m.content.flatMap((b) => b.type === "toolCall" ? [[b.id, b.name] as const] : []) : []));
    const messages = event.messages.map((m, i) => {
      if (i >= recentStart || m.role !== "toolResult" || m.isError || m.toolName !== "read"
        || calls.get(m.toolCallId) !== "read" || !m.content.every(b => b.type === "text")) return m;
      const keep = scores?.answers?.[m.toolCallId]?.noul;
      if (typeof keep !== "number" || !Number.isFinite(keep) || keep < 0 || keep > 0.1) return m;
      return { ...m, content: [{ type: "text" as const,
        text: "[Earlier read output omitted from this request; original preserved in the saved session.]" }] };
    });
    writeFileSync(join(ctx.cwd, "filtered.json"), JSON.stringify(messages));
    return { messages };
  });
}
