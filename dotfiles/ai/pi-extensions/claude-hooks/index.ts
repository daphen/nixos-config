import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

// heidr writes the focused rail nvim's pid here (empty when none focused). If a
// live rail holds focus you're at the cockpit and the roster already shows the
// session settle — so a desktop toast would be noise (matches heidr's own guard).
function railFocused(): boolean {
  try {
    const pid = parseInt(readFileSync(join(process.env.XDG_RUNTIME_DIR ?? "/tmp", "agent-rail-focused"), "utf8").trim(), 10);
    if (!pid) return false;
    process.kill(pid, 0); // throws if the pid is dead → not focused
    return true;
  } catch {
    return false;
  }
}

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

  // After `pi --continue` (a session reload), pi marks the pre-reload ctx stale and
  // THROWS on any access to it — cwd, sessionManager, etc. A hook that touches ctx
  // then aborts the whole turn (the "resumed session replies instantly with nothing"
  // bug). A tracking/notify hook must never do that: read ctx defensively and, if it's
  // stale, skip our side-effect rather than crash pi's turn.
  function ctxInfo(ctx: any): { cwd: string; sessionId: string } | null {
    try {
      return { cwd: ctx.cwd, sessionId: ctx.sessionManager.getSessionId() };
    } catch {
      return null; // stale ctx after reload — degrade, don't throw
    }
  }

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

    const info = ctxInfo(ctx);
    if (!info) return { action: "continue" }; // stale ctx post-reload — pass the prompt through unchanged
    const injected = run(WT_STATE_INJECT, [], JSON.stringify({
      cwd: info.cwd,
      session_id: info.sessionId,
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

    const info = ctxInfo(ctx);
    if (!info) return; // stale ctx post-reload — skip tracking rather than abort
    const isError = Boolean((event as any).isError);
    // ai-tracker rejects relative paths; pi passes through whatever the model wrote.
    const filePath = isAbsolute(args.path ?? "") ? args.path : resolve(info.cwd, args.path ?? "");

    if (name === "write") {
      track("Write", { file_path: filePath, content: args.content }, info.cwd, isError);
      return;
    }

    // pi batches edits per call; ai-tracker logs one change per invocation.
    for (const e of args.edits ?? []) {
      track("Edit", {
        file_path: filePath,
        old_string: e.oldText,
        new_string: e.newText,
        replace_all: Boolean(e.replaceAll),
      }, info.cwd, isError);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (railFocused()) return; // you're at the cockpit — the roster shows it; don't toast
    const info = ctxInfo(ctx);
    if (!info) return; // stale ctx after --continue reload — skip the toast, never throw into the turn
    run(NOTIFY, [], JSON.stringify({
      app: "Heidr", // brand the toast as Heidr, not Claude (the script also infers this)
      cwd: info.cwd,
      message: "Waiting for input",
      session_id: info.sessionId,
    }));
  });
}
