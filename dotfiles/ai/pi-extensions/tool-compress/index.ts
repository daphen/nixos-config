import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  DEFAULT_MAX_BYTES,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";

const BUILTIN_TOOLS = new Set(["bash", "read", "edit", "write", "grep", "find", "ls"]);
const HEAD_BYTES = 40 * 1024;
const TAIL_BYTES = 8 * 1024;
const MARKER_PREFIX = "… [trimmed to ";
const BLOB_DIR = join(homedir(), ".pi", "agent", "tool-blobs");

function sliceHeadUtf8(text: string, maxBytes: number): string {
  const bytes = Buffer.from(text);
  let end = Math.min(maxBytes, bytes.length);
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
  return bytes.subarray(0, end).toString("utf8");
}

function sliceTailUtf8(text: string, maxBytes: number): string {
  const bytes = Buffer.from(text);
  let start = Math.max(0, bytes.length - maxBytes);
  while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start++;
  return bytes.subarray(start).toString("utf8");
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", async (event) => {
    let originalContent: typeof event.content | undefined;

    try {
      originalContent = event.content;
      if (BUILTIN_TOOLS.has(event.toolName)) return;

      const oversized = event.content.some(
        (block) =>
          block.type === "text" &&
          !block.text.includes(MARKER_PREFIX) &&
          Buffer.byteLength(block.text, "utf8") > DEFAULT_MAX_BYTES,
      );
      if (!oversized) return;

      const safeCallId = event.toolCallId.replace(/[^a-zA-Z0-9._-]/g, "_");
      const sidecarPath = join(BLOB_DIR, `${safeCallId}.txt`);
      const rawText = event.content
        .filter((block) => block.type === "text")
        .map((block) => block.text)
        .join("\n\n");

      await mkdir(BLOB_DIR, { recursive: true, mode: 0o700 });
      await writeFile(sidecarPath, rawText, { encoding: "utf8", mode: 0o600 });

      const marker = `… [trimmed to ${DEFAULT_MAX_BYTES / 1024} KB — full: ${sidecarPath}] …`;
      const content = event.content.map((block) => {
        if (
          block.type !== "text" ||
          block.text.includes(MARKER_PREFIX) ||
          Buffer.byteLength(block.text, "utf8") <= DEFAULT_MAX_BYTES
        ) {
          return block;
        }

        return {
          ...block,
          text: `${sliceHeadUtf8(block.text, HEAD_BYTES)}\n\n${marker}\n\n${sliceTailUtf8(block.text, TAIL_BYTES)}`,
        };
      });

      return { content };
    } catch (error) {
      if (process.env.PI_TOOL_COMPRESS_DEBUG === "1") {
        console.error("[tool-compress] Failed open:", error);
      }
      return originalContent ? { content: originalContent } : undefined;
    }
  });
}
