import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import { execFile } from "node:child_process";

import { allSessions, readSessionTurns, resolveSession, scheduleSelf, sendPrompt, spawnSession, steerSession, stopSelf } from "./agentd.ts";

// Native coordination tools for pi agents driven by the Heidr rail / agentd.
// The desktop (niri pickers, nvim keybinds, cockpit scripts) uses the sibling
// `agent` CLI, which speaks the same agentd socket protocol. Both replace the
// retired wt-* scripts; neither is worktree-coupled.
//
// SPAWN-LINEAGE GATE (enforced in agentd, not here): a WORKER may agent_send /
// agent_steer only to sessions in its own spawn lineage — ones it spawned, or the one
// that spawned it. So a worker can stand up a sub-agent team and converse with it, but
// CANNOT inject a task into an unrelated already-open session (the EVERY-2661 fan-out).
// EXEMPTION: the ORCHESTRATOR — the session in the main checkout (cwd == the scope's
// repo root) — is the coordination hub and may message ANY session in its scope. So the
// orchestrator hands a ticket session new work by agent_send-ing it DIRECTLY, not by
// spawning a parallel worker to carry the context. agentd gates by the `from` (caller)
// field the client stamps; human sends via the rail / `agent` CLI carry no `from`, never gated.
const say = (s: string) => ({ content: [{ type: "text" as const, text: s }], details: undefined });

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "agent_roster",
    label: "Agent roster",
    description:
      "List the live agent sessions across every scope (scope · status · name · cwd). Run this first to discover who else is running before sending or reading.",
    promptSnippet: "agent_roster: list live agent sessions",
    parameters: Type.Object({}),
    async execute() {
      const sessions = await allSessions();
      if (sessions.length === 0) return say("No active agent sessions.");
      const rows = sessions.map(
        (s) => `${(s.scope ?? "?").padEnd(8)} ${String(s.status ?? "?").padEnd(10)} ${String(s.profile ?? "?").padEnd(22)} ${String(s.name ?? "?").padEnd(36)} ${s.cwd ?? ""}`,
      );
      return say(rows.join("\n"));
    },
  });

  pi.registerTool({
    name: "agent_read",
    label: "Read agent",
    description:
      "Read another agent's last N user+assistant turns WITHOUT interrupting it. `agent` is a session name, id, or cwd. Use to check what a busy agent is doing.",
    promptSnippet: "agent_read: read another agent's recent turns",
    parameters: Type.Object({
      agent: Type.String({ description: "session name, id, or cwd" }),
      turns: Type.Optional(Type.Number({ description: "how many recent turns (default 6)" })),
    }),
    async execute(_id, params: any) {
      try {
        const r = await resolveSession(params.agent);
        if (!r) return say(`No agent session matching ${JSON.stringify(params.agent)}.`);
        const read = await readSessionTurns(r, params.turns ?? 6);
        if (!read || read.turns.length === 0) return say(`No transcript found for ${r.session.name ?? r.cwd}.`);
        const body = read.turns.map((t) => `${t.role === "user" ? "▶ user" : "◀ agent"}:\n${t.text}`).join("\n\n");
        return say(`# ${r.session.name ?? r.cwd} (${r.cwd})\n\n${body}`);
      } catch (error) {
        return say(String((error as Error).message ?? error));
      }
    },
  });

  pi.registerTool({
    name: "agent_send",
    label: "Send to agent",
    description:
      "Dispatch a prompt to another agent's session. If you are the ORCHESTRATOR (running in the main checkout), you may send to ANY session in your scope — so to give a ticket session new context or direction, agent_send THAT session DIRECTLY (e.g. send the finalized direction to every-2661); it will spawn its own sub-workers if it needs them. Do NOT spawn a parallel planning/audit/direction agent just to deliver context to a session that already exists — send to the existing session. WORKERS (not the orchestrator) remain spawn-lineage-gated: you may only message a session you spawned or the one that spawned you; to bring in a NEW helper, agent_spawn it first (full context in the seed prompt), then converse.",
    promptSnippet: "agent_send: dispatch a prompt to a session (orchestrator: any; worker: own lineage)",
    parameters: Type.Object({
      agent: Type.String({ description: "session name, id, or cwd" }),
      message: Type.String({ description: "the prompt to deliver" }),
    }),
    async execute(_id, params: any) {
      try {
        const r = await sendPrompt(params.agent, params.message);
        return say(`Delivered to ${r.session.name ?? r.cwd} (${r.scope}).`);
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_steer",
    label: "Steer agent",
    description:
      "Redirect another agent IN REAL TIME while it's mid-turn: the message is delivered into its running turn at the next tool boundary (before its next LLM call), not queued to turn-end. Use to course-correct a working agent ('stop, do X instead'). If the target is idle it falls back to a normal prompt so nothing is lost. Same reach as agent_send: the orchestrator (main checkout) may steer ANY session in its scope; a worker only a session in its own spawn lineage.",
    promptSnippet: "agent_steer: redirect an agent in your spawn lineage mid-turn",
    parameters: Type.Object({
      agent: Type.String({ description: "session name, id, or cwd" }),
      message: Type.String({ description: "the steering instruction to inject" }),
    }),
    async execute(_id, params: any) {
      try {
        const { resolved, delivered } = await steerSession(params.agent, params.message);
        const who = `${resolved.session.name ?? resolved.cwd} (${resolved.scope})`;
        return say(delivered === "steer" ? `Steered ${who} mid-turn.` : `${who} was idle — sent as a normal prompt.`);
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_review",
    label: "Review a PR",
    description:
      "Spin up a Pi-native PR review: fetches the PR onto its OWN review/pr-<n> worktree and starts a rail session there seeded with /review-pr (it runs the full review and writes the artifact; posts nothing to GitHub). Use THIS for PR reviews — NOT agent_spawn, which has no worktree/PR checkout so the review has nothing to look at. `pr` is a number or a GitHub PR URL.",
    promptSnippet: "agent_review: review a PR in its own worktree",
    parameters: Type.Object({
      pr: Type.String({ description: "PR number or GitHub PR URL" }),
      devenv: Type.Optional(Type.Boolean({ description: "also boot devenv for the review worktree" })),
    }),
    async execute(_id, params: any) {
      const bin = (process.env.HOME ?? "") + "/.local/bin/agent";
      const args = ["review", String(params.pr)];
      if (params.devenv) args.push("--devenv");
      return await new Promise((resolve) => {
        execFile(bin, args, { timeout: 120_000 }, (err, _out, stderr) => {
          if (err) resolve(say("agent review failed: " + String(stderr || (err as Error).message).trim()));
          else resolve(say(`Started a PR review for ${params.pr} on its own review/pr worktree — a rail session is running /review-pr; open it from the roster when it settles.`));
        });
      });
    },
  });

  pi.registerTool({
    name: "agent_schedule_self",
    label: "Schedule watcher check",
    description: "Watcher-only: schedule this same watcher to receive one check prompt in about three minutes, persist the timer in agentd, and end the current turn idle.",
    parameters: Type.Object({}),
    async execute() {
      try {
        await scheduleSelf();
        return say("Next watcher check scheduled in about three minutes. End this turn now; do not sleep or poll.");
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_stop_self",
    label: "Stop watcher",
    description: "Watcher-only: stop this watcher and cancel its persisted timer after its final parent report.",
    parameters: Type.Object({}),
    async execute() {
      try {
        await stopSelf();
        return say("Watcher stopped.");
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_spawn",
    label: "Spawn agent",
    description:
      "Start a NEW agent session in an existing directory (a fresh roster item). Children inherit the caller's profile server-side unless profile is supplied; the only permitted transition is lovable-worker to lovable-watcher. Does NOT create worktrees — pass a real dir.",
    promptSnippet: "agent_spawn: start a new agent session in a dir",
    parameters: Type.Object({
      dir: Type.String({ description: "existing directory to run the session in" }),
      prompt: Type.Optional(Type.String({ description: "seed prompt delivered on spawn" })),
      name: Type.Optional(Type.String({ description: "session name (default: dir basename)" })),
      scope: Type.Optional(Type.String({ description: "agentd scope (default: caller's scope, then inferred from dir)" })),
      profile: Type.Optional(StringEnum(["lovable-orchestrator", "lovable-worker", "lovable-reviewer", "lovable-watcher", "coding", "chat"] as const, { description: "validated profile; omit to inherit server-side" })),
      oneshot: Type.Optional(Type.Boolean({ description: "ephemeral: run the seed once then exit" })),
    }),
    async execute(_id, params: any) {
      try {
        const r = await spawnSession(params.dir, {
          prompt: params.prompt,
          name: params.name,
          scope: params.scope,
          profile: params.profile,
          oneshot: params.oneshot,
        });
        return say(
          `Spawned '${r.name}' in the ${r.scope} rail (cwd ${r.dir})` +
            (params.prompt ? " + seeded prompt" : "") +
            (params.oneshot ? " [oneshot]" : "") +
            ` · profile ${params.profile ?? "inherited"}.`,
        );
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_whoami",
    label: "Who am I",
    description: "Return this agent's own registered session name (and scope), resolved from its working directory.",
    promptSnippet: "agent_whoami: this agent's own session name",
    parameters: Type.Object({}),
    async execute() {
      const r = await resolveSession(process.cwd());
      if (!r) return say(`Not registered in any roster (cwd ${process.cwd()}).`);
      return say(`${r.session.name ?? "(unnamed)"} · ${r.scope} · ${r.cwd}`);
    },
  });
}
