import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import os from "node:os";
import { Type } from "typebox";

export const USER_BASH_TITLE = "__cockpit_user_bash__";
export const USER_BASH_APPROVAL_ENTRY = "cockpit-user-bash-approval";
const MAX_OUTPUT = 50 * 1024;

export type UserBashRequest = { command: string; reason: string; cwd: string; host: string };
export type UserBashApproval = UserBashRequest & { decision: "approved" };
export type UserBashResult = { output: string; exitCode: number };
type Confirm = (title: string, message: string) => Promise<boolean>;
type Runner = (command: string, cwd: string, signal?: AbortSignal) => Promise<UserBashResult>;

const say = (text: string) => ({ content: [{ type: "text" as const, text }], details: undefined });

export async function runUserBash(
  request: UserBashRequest,
  confirm: Confirm,
  runner: Runner,
  signal?: AbortSignal,
  recordApproval?: (approval: UserBashApproval) => void,
) {
  if (!await confirm(USER_BASH_TITLE, JSON.stringify(request))) return say("declined — command was not run");
  recordApproval?.({ ...request, decision: "approved" });
  const result = await runner(request.command, request.cwd, signal);
  const body = result.output.trimEnd();
  const text = `${body ? `${body}\n\n` : ""}Command exited with code ${result.exitCode}`;
  if (result.exitCode !== 0) throw new Error(text);
  return say(text);
}

export function executeBash(command: string, cwd: string, signal?: AbortSignal): Promise<UserBashResult> {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", ["-lc", command], { cwd, signal, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    const append = (chunk: Buffer) => { output = (output + chunk.toString()).slice(-MAX_OUTPUT); };
    child.stdout.on("data", append);
    child.stderr.on("data", append);
    child.on("error", reject);
    child.on("close", code => resolve({ output, exitCode: code ?? 1 }));
  });
}

export default function (pi: ExtensionAPI) {
  let requestedThisTurn = false;
  pi.on("input", () => { requestedThisTurn = false; });
  pi.registerTool({
    name: "request_user_bash",
    label: "Run as user",
    description:
      "Ask the user to run one exact bash command that you cannot run yourself. " +
      "This blocks on a human-only inline Cockpit card; nothing executes until the user clicks Run. " +
      "Provide the exact immutable command and why the handoff is needed. The command runs in this session's cwd/host and its result returns to this tool call. " +
      "You may request only one command per user turn; after its result, report the outcome instead of requesting another.",
    promptSnippet: "request_user_bash: hand an unavailable command to the user via an inline Run card",
    parameters: Type.Object({
      command: Type.String({ description: "Exact bash command to show and run after the human click" }),
      reason: Type.String({ description: "Why you cannot run it and what it will do" }),
    }),
    async execute(_id: string, params: any, signal: AbortSignal, _onUpdate: unknown, ctx: ExtensionContext) {
      if (requestedThisTurn)
        throw new Error("A command was already handed to the user this turn. Do not request another; report the result and wait for a new user instruction.");
      requestedThisTurn = true;
      const request: UserBashRequest = {
        command: String(params.command),
        reason: String(params.reason),
        cwd: ctx.cwd,
        host: os.hostname(),
      };
      return runUserBash(
        request,
        (title, message) => ctx.ui.confirm(title, message),
        executeBash,
        signal,
        approval => pi.appendEntry<UserBashApproval>(USER_BASH_APPROVAL_ENTRY, approval),
      );
    },
  });
}
