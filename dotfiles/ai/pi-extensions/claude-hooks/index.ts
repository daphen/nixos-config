import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

const HOOKS = "/home/daphen/.claude/hooks";
const WT_STATE_INJECT = "/home/daphen/.local/bin/wt-state-inject";
const COCKPIT_CLEAR = `${HOOKS}/cockpit-wants-input-clear.sh`;
const NOTIFY = `${HOOKS}/notify-with-context.sh`;
const AI_TRACKER = `${HOOKS}/ai-tracker.js`;

function run(cmd: string, args: string[], stdin?: string): string {
  try {
    const r = spawnSync(cmd, args, { input: stdin ?? "", encoding: "utf8", timeout: 10_000 });
    return r.stdout ?? "";
  } catch {
    return "";
  }
}

export default function (pi: ExtensionAPI) {
  let lastPrompt = "";
  // tool_execution_end carries no args, so stash them from _start by call id.
  const pendingArgs = new Map<string, any>();

  // ai-tracker reads the triggering prompt out of a Claude-format transcript.
  // pi's session format differs, so hand it a one-line stand-in instead.
  let promptFile: string | null = null;
  function transcriptStandIn(): string {
    if (!promptFile) promptFile = join(mkdtempSync(join(tmpdir(), "pi-hooks-")), "t.jsonl");
    writeFileSync(promptFile, JSON.stringify({ role: "user", content: lastPrompt }) + "\n");
    return promptFile;
  }

  function track(claudeTool: string, toolInput: Record<string, unknown>, cwd: string, isError: boolean) {
    run("node", [AI_TRACKER], JSON.stringify({
      cwd,
      tool_name: claudeTool,
      tool_input: toolInput,
      tool_response: isError ? { error: true } : {},
      transcript_path: transcriptStandIn(),
    }));
  }

  pi.on("input", async (event, ctx) => {
    if (event.source === "extension") return { action: "continue" };
    lastPrompt = event.text;
    run(COCKPIT_CLEAR, []);

    // Prepending would break `/skill:x` and `/template` dispatch, which the
    // input event sees pre-expansion — so only inject on plain prose.
    if (event.text.startsWith("/")) return { action: "continue" };

    const injected = run(WT_STATE_INJECT, [], JSON.stringify({
      cwd: ctx.cwd,
      session_id: ctx.sessionManager.getSessionId(),
    })).trim();

    if (!injected) return { action: "continue" };
    return { action: "transform", text: `${injected}\n\n${event.text}` };
  });

  pi.on("tool_execution_start", async (event) => {
    const name = (event as any).toolName;
    if (name === "write" || name === "edit") {
      pendingArgs.set((event as any).toolCallId, (event as any).args ?? {});
    }
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    run(COCKPIT_CLEAR, []);

    const id = (event as any).toolCallId;
    const name = (event as any).toolName;
    const args = pendingArgs.get(id);
    pendingArgs.delete(id);
    if (!args) return;

    const isError = Boolean((event as any).isError);
    // ai-tracker rejects relative paths; pi passes through whatever the model wrote.
    const filePath = isAbsolute(args.path ?? "") ? args.path : resolve(ctx.cwd, args.path ?? "");

    if (name === "write") {
      track("Write", { file_path: filePath, content: args.content }, ctx.cwd, isError);
      return;
    }

    // pi batches edits per call; ai-tracker logs one change per invocation.
    for (const e of args.edits ?? []) {
      track("Edit", {
        file_path: filePath,
        old_string: e.oldText,
        new_string: e.newText,
        replace_all: Boolean(e.replaceAll),
      }, ctx.cwd, isError);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    run(NOTIFY, [], JSON.stringify({
      cwd: ctx.cwd,
      message: "Waiting for input",
      session_id: ctx.sessionManager.getSessionId(),
    }));
  });
}
