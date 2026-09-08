import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const MAX_SUMMARY_BYTES = 20_000;
const USER_BYTES = 6_000;
const PREFIX_BYTES = 4_000;
const OUTCOME_BYTES = 3_500;
const FILE_BYTES = 2_500;
const PRIOR_BYTES = 3_000;

function truncateUtf8(text: string, limit: number): string {
  const bytes = Buffer.from(text);
  if (bytes.length <= limit) return text;
  let end = limit - Buffer.byteLength("\n… [truncated]", "utf8");
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
  return `${bytes.subarray(0, end).toString("utf8")}\n… [truncated]`;
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((block) => {
    if (!block || typeof block !== "object") return "";
    const value = block as { type?: string; text?: string; mimeType?: string };
    if (value.type === "text") return value.text ?? "";
    if (value.type === "image") return `[image omitted: ${value.mimeType ?? "unknown type"}]`;
    return "";
  }).filter(Boolean).join("\n");
}

function splitPrefixNotes(messages: any[]): string[] {
  const notes: string[] = [];
  const pendingTools = new Map<string, string>();
  for (const message of messages) {
    if (message.role === "user") notes.push(`user: ${contentText(message.content)}`);
    if (message.role === "assistant" && Array.isArray(message.content)) {
      const text = contentText(message.content).trim();
      if (text) notes.push(`assistant: ${text}`);
      for (const block of message.content) {
        if (block?.type === "toolCall" && block.id) pendingTools.set(block.id, block.name ?? "unknown");
      }
    }
    if (message.role === "toolResult" && pendingTools.has(message.toolCallId)) {
      notes.push(`tool ${pendingTools.get(message.toolCallId)} completed: ${contentText(message.content)}`);
      pendingTools.delete(message.toolCallId);
    }
  }
  return notes;
}

function newestWithin(items: string[], limit: number, prefix: string): string {
  const selected: string[] = [];
  let used = 0;
  for (let i = items.length - 1; i >= 0; i--) {
    const value = truncateUtf8(items[i].trim(), 1_200);
    if (!value) continue;
    const line = `${prefix}${value}`;
    const bytes = Buffer.byteLength(line, "utf8");
    if (used + bytes > limit) break;
    selected.unshift(line);
    used += bytes;
  }
  return selected.join("\n\n");
}

function fileSection(fileOps: { read: Set<string>; written: Set<string>; edited: Set<string> }): {
  text: string;
  readFiles: string[];
  modifiedFiles: string[];
} {
  const modifiedFiles = [...new Set([...fileOps.written, ...fileOps.edited])].sort();
  const modified = new Set(modifiedFiles);
  const readFiles = [...fileOps.read].filter((path) => !modified.has(path)).sort();
  const lines = [
    ...modifiedFiles.map((path) => `- modified: ${path}`),
    ...readFiles.map((path) => `- read: ${path}`),
  ];
  return { text: truncateUtf8(lines.join("\n") || "- none recorded", FILE_BYTES), readFiles, modifiedFiles };
}

export default function noSummaryRollover(pi: ExtensionAPI) {
  pi.on("session_before_compact", (event) => {
    if (event.reason !== "threshold" && event.reason !== "overflow") return;
    const preparation = event.preparation;
    if (preparation.messagesToSummarize.length === 0 && preparation.turnPrefixMessages.length === 0 && !preparation.previousSummary) return;

    const users: string[] = [];
    const outcomes: string[] = [];
    const replacedMessages = [...preparation.messagesToSummarize, ...preparation.turnPrefixMessages];
    for (const message of replacedMessages) {
      if (message.role === "user") users.push(contentText(message.content));
      if (message.role === "assistant") {
        const recaps = contentText(message.content).split("\n").filter((line) => line.startsWith("⟢ "));
        if (recaps.length > 0) outcomes.push(recaps[recaps.length - 1]);
      }
    }

    const files = fileSection(event.preparation.fileOps);
    const sections = [
      "# Recovery checkpoint (deterministic, not proof)",
      "Verify current files and external state before any stateful action. Pi retained the recent conversation separately; this record covers only older replaced context.",
      `## Older user instructions\n${newestWithin(users, USER_BYTES, "- ") || "- none retained"}`,
      ...(preparation.isSplitTurn ? [`## Earlier part of retained task\n${newestWithin(splitPrefixNotes(preparation.turnPrefixMessages), PREFIX_BYTES, "- ") || "- none retained"}`] : []),
      `## Recorded turn outcomes\n${newestWithin(outcomes, OUTCOME_BYTES, "- ") || "- none retained"}`,
      `## Cumulative files\n${files.text}`,
      `## Previous checkpoint (possibly stale)\n${truncateUtf8(event.preparation.previousSummary ?? "- none", PRIOR_BYTES)}`,
    ];
    const summary = truncateUtf8(sections.join("\n\n"), MAX_SUMMARY_BYTES);

    return {
      compaction: {
        summary,
        firstKeptEntryId: preparation.firstKeptEntryId,
        tokensBefore: preparation.tokensBefore,
        details: { strategy: "deterministic-auto-v3", readFiles: files.readFiles, modifiedFiles: files.modifiedFiles },
      },
    };
  });
}
