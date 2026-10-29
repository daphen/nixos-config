import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const RECORD = "context-trim";
const KEEP_USER_TURNS = 2;
const TRIGGER_PERCENT = 50;
const MIN_SAVING_BYTES = 80_000;
const IMAGE_BYTES = 12_000;
const LARGE_BYTES = 2_048;
const HEAD_BYTES = 600;
const TAIL_BYTES = 400;

type Block = { type: string; text?: string; [key: string]: unknown };
type Msg = { role: string; timestamp?: number; content?: string | Block[]; toolName?: string; toolCallId?: string; [key: string]: unknown };

function utf8Slice(text: string, start: number, end: number) {
  const bytes = Buffer.from(text);
  while (start > 0 && start < bytes.length && (bytes[start] & 0xc0) === 0x80) start++;
  while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
  return bytes.subarray(start, Math.max(start, end)).toString("utf8");
}

function imagePaths(messages: Msg[]) {
  const paths = new Map<string, string>();
  for (const m of messages)
    if (m.role === "assistant" && Array.isArray(m.content))
      for (const b of m.content)
        if (b.type === "toolCall" && typeof (b.arguments as { path?: unknown })?.path === "string")
          paths.set(b.id as string, (b.arguments as { path: string }).path);
  return paths;
}

function trimMessage(m: Msg, paths: Map<string, string>): { message: Msg; saved: number } {
  if ((m.role !== "toolResult" && m.role !== "user") || !Array.isArray(m.content)) return { message: m, saved: 0 };
  let saved = 0;
  const content = m.content.map(b => {
    if (b.type === "image") {
      saved += IMAGE_BYTES;
      const path = m.toolCallId ? paths.get(m.toolCallId) : undefined;
      return { type: "text", text: `[Old image removed from context${path ? `; reread ${JSON.stringify(path)} if needed` : ""}.]` };
    }
    // Old read text is Jev's to judge; it is also cheaply re-readable.
    if (b.type !== "text" || m.role !== "toolResult" || m.toolName === "read" || typeof b.text !== "string") return b;
    const size = Buffer.byteLength(b.text);
    if (size <= LARGE_BYTES) return b;
    const text = `${utf8Slice(b.text, 0, HEAD_BYTES)}\n… [${size - HEAD_BYTES - TAIL_BYTES} bytes of old output removed from context; the full output is saved in the session file.] …\n${utf8Slice(b.text, size - TAIL_BYTES, size)}`;
    saved += size - Buffer.byteLength(text);
    return { ...b, text };
  });
  return saved ? { message: { ...m, content }, saved } : { message: m, saved: 0 };
}

function trim(messages: Msg[], cutoff: number) {
  const paths = imagePaths(messages);
  let saved = 0;
  const out = messages.map(m => {
    if (typeof m.timestamp !== "number" || m.timestamp >= cutoff) return m;
    const r = trimMessage(m, paths);
    saved += r.saved;
    return r.message;
  });
  return { messages: out, saved };
}

function savedCutoff(ctx: ExtensionContext) {
  const entry = ctx.sessionManager.getBranch().findLast(e => e.type === "custom" && e.customType === RECORD);
  const cutoff = entry?.type === "custom" ? (entry.data as { cutoff?: unknown })?.cutoff : undefined;
  return typeof cutoff === "number" ? cutoff : 0;
}

export default function contextTrim(pi: ExtensionAPI) {
  pi.on("context", async (event, ctx) => {
    const messages = event.messages as unknown as Msg[];
    let cutoff = savedCutoff(ctx);
    const percent = ctx.getContextUsage()?.percent;
    const users = messages.filter(m => m.role === "user" && typeof m.timestamp === "number");
    const candidate = users.length >= KEEP_USER_TURNS ? users[users.length - KEEP_USER_TURNS].timestamp! : 0;
    // The cutoff only moves in large steps, so the prompt cache is rebuilt once per step, not per turn.
    if (percent != null && percent >= TRIGGER_PERCENT && candidate > cutoff
      && trim(messages, candidate).saved - trim(messages, cutoff).saved >= MIN_SAVING_BYTES) {
      cutoff = candidate;
      pi.appendEntry(RECORD, { cutoff });
    }
    if (!cutoff) return;
    const result = trim(messages, cutoff);
    if (result.saved) return { messages: result.messages as unknown as typeof event.messages };
  });
}
