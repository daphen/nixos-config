import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import { execFile } from "node:child_process";

import {
  allSessions,
  answerSession,
  dispositionReviewFindings,
  readSessionTurns,
  reportReviewFindings,
  resolveSession,
  scheduleSelf,
  sendPrompt,
  setPlan,
  spawnSession,
  steerSession,
  stopSelf,
} from "./agentd.ts";

// Native coordination tools for pi agents driven by Cockpit / agentd.
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
      const rows = sessions.map((s) => {
        const plan = s.plan ? ` · plan: ${s.plan}` : "";
        const ask = s.ask?.title ? ` · needs input: ${JSON.stringify(s.ask.title)}` : "";
        return `${(s.scope ?? "?").padEnd(8)} ${String(s.status ?? "?").padEnd(10)} ${String(s.profile ?? "?").padEnd(22)} ${String(s.name ?? "?").padEnd(36)} ${s.cwd ?? ""}${plan}${ask}`;
      });
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
    name: "agent_answer",
    label: "Answer agent",
    description:
      "Answer a pending ask_user question in another agent session. Use yes/no for confirmations, option text or its 1-based number for choices, free text for inputs, or cancel.",
    promptSnippet: "agent_answer: answer an agent's pending question",
    parameters: Type.Object({
      agent: Type.String({ description: "session name, id, or cwd" }),
      answer: Type.String({ description: "yes/no, option text or number, input text, or cancel" }),
    }),
    async execute(_id, params: any) {
      try {
        const r = await answerSession(params.agent, params.answer);
        return say(`Answered ${r.session.name ?? r.cwd} (${r.scope}).`);
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_set_plan",
    label: "Set session plan",
    description:
      "Bind this calling agent session to a vault plan slug, replacing its previous binding. Pass an empty string to clear the binding.",
    promptSnippet: "agent_set_plan: bind or clear this session's plan slug",
    parameters: Type.Object({
      plan: Type.String({ description: "vault plan slug, or an empty string to clear" }),
    }),
    async execute(_id, params: any) {
      try {
        const r = await setPlan(params.plan);
        return say(params.plan ? `Bound ${r.session.name ?? r.cwd} to plan ${params.plan}.` : `Cleared the plan binding for ${r.session.name ?? r.cwd}.`);
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
      pr: Type.Optional(Type.String({ description: "PR number or GitHub PR URL; omit only for teardown" })),
      devenv: Type.Optional(Type.Boolean({ description: "also boot local devenv for the review worktree" })),
      manualTestProject: Type.Optional(Type.String({ description: "prepare the canonical VM-backed manual-test harness for this project UUID" })),
      browserProfileSeed: Type.Optional(Type.String({ description: "authenticated stopped Chromium profile to clone into the isolated context" })),
      allowSandboxStart: Type.Optional(Type.Boolean({ description: "allow exactly one bounded browser-flow sandbox start when no live iframe exists; requires explicit current-turn approval" })),
      teardownContext: Type.Optional(Type.String({ description: "stop and remove one owned pr-N manual-test context; mutually exclusive with pr" })),
    }),
    async execute(_id, params: any) {
      const bin = (process.env.HOME ?? "") + "/.local/bin/agent";
      if (params.teardownContext && (params.pr || params.devenv || params.manualTestProject || params.browserProfileSeed || params.allowSandboxStart)) {
        return say("agent review failed: teardownContext is mutually exclusive with startup options");
      }
      if (!params.teardownContext && !params.pr) return say("agent review failed: pr is required unless teardownContext is set");
      const args = params.teardownContext
        ? ["review", "--teardown", String(params.teardownContext)]
        : ["review", String(params.pr)];
      if (params.devenv) args.push("--devenv");
      if (params.manualTestProject) args.push("--manual-test", String(params.manualTestProject));
      if (params.browserProfileSeed) args.push("--browser-profile-seed", String(params.browserProfileSeed));
      if (params.allowSandboxStart) args.push("--allow-sandbox-start");
      return await new Promise((resolve) => {
        execFile(bin, args, { timeout: 600_000 }, (err, _out, stderr) => {
          if (err) resolve(say("agent review failed: " + String(stderr || (err as Error).message).trim()));
          else if (params.teardownContext) resolve(say(`Removed owned manual-test context ${params.teardownContext}.`));
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
    name: "agent_report_review_findings",
    label: "Report PR review findings",
    description: "Watcher-only: send typed new PR review findings to this watcher's worker parent and open an auditable remediation context bound to the PR branch and head.",
    parameters: Type.Object({
      pr: Type.Number({ description: "GitHub PR number" }),
      branch: Type.String({ description: "exact PR head branch" }),
      head: Type.String({ description: "exact PR head commit SHA" }),
      findings: Type.Array(Type.Object({
        id: Type.String({ description: "stable review finding/thread identifier" }),
        url: Type.String({ description: "finding or review-thread URL" }),
        paths: Type.Array(Type.String({ description: "files permitted to change for this finding" }), { minItems: 1 }),
      }), { minItems: 1 }),
    }),
    async execute(_id, params: any) {
      try {
        const contextId = await reportReviewFindings(params.pr, params.branch, params.head, params.findings);
        return say(`Reported ${params.findings.length} typed finding(s) to the worker · remediation context ${contextId}.`);
      } catch (e) {
        return say(String((e as Error).message ?? e));
      }
    },
  });

  pi.registerTool({
    name: "agent_disposition_review_findings",
    label: "Disposition PR review findings",
    description: "Worker-only: mark every finding in one typed remediation context implemented+tested or rejected. A fully validated disposition can mint one same-branch non-force push grant.",
    parameters: Type.Object({
      contextId: Type.String(),
      outcome: StringEnum(["implemented", "rejected"] as const),
      findings: Type.Array(Type.Object({ id: Type.String(), implemented: Type.Boolean(), tested: Type.Boolean() }), { minItems: 1 }),
      tests: Type.Array(Type.String(), { description: "commands/results proving remediation validation" }),
      commits: Type.Array(Type.String(), { description: "exact remediation commit SHAs" }),
    }),
    async execute(_id, params: any) {
      try {
        await dispositionReviewFindings(params.contextId, params.outcome, params.findings, params.tests, params.commits);
        return say(params.outcome === "implemented" ? "Recorded implemented+tested findings; one same-branch remediation push is eligible." : "Recorded rejected findings; no push grant was created.");
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
      "Start a NEW agent session in an existing directory (a fresh roster item). Choose the relationship: default = a CHILD in your spawn lineage (renders indented under you; you can agent_send/steer it afterward); detached=true = an INDEPENDENT top-level session (roster root, no parent — hand the task over fully in the seed prompt, because you cannot message it afterward unless you are the orchestrator). Children inherit the caller's profile server-side unless profile is supplied; the only permitted transition is lovable-worker to lovable-watcher. Does NOT create worktrees — pass a real dir.",
    promptSnippet: "agent_spawn: start a new agent session in a dir",
    parameters: Type.Object({
      dir: Type.String({ description: "existing directory to run the session in" }),
      prompt: Type.Optional(Type.String({ description: "seed prompt delivered on spawn" })),
      name: Type.Optional(Type.String({ description: "session name (default: dir basename)" })),
      scope: Type.Optional(Type.String({ description: "agentd scope (default: caller's scope, then inferred from dir)" })),
      profile: Type.Optional(StringEnum(["lovable-orchestrator", "lovable-worker", "lovable-reviewer", "lovable-watcher", "coding", "chat"] as const, { description: "validated profile; omit to inherit server-side" })),
      oneshot: Type.Optional(Type.Boolean({ description: "ephemeral: run the seed once then exit" })),
      detached: Type.Optional(Type.Boolean({ description: "true = independent top-level session (no lineage, not messageable by you afterward); omit/false = child in your lineage" })),
    }),
    async execute(_id, params: any) {
      try {
        const r = await spawnSession(params.dir, {
          prompt: params.prompt,
          name: params.name,
          scope: params.scope,
          profile: params.profile,
          oneshot: params.oneshot,
          detached: params.detached,
        });
        return say(
          `Spawned '${r.name}' in the ${r.scope} rail (cwd ${r.dir})` +
            (params.prompt ? " + seeded prompt" : "") +
            (params.oneshot ? " [oneshot]" : "") +
            (params.detached ? " [detached: top-level, not in your lineage — you cannot message it]" : "") +
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
      return say(`${r.session.name ?? "(unnamed)"} · ${r.scope} · ${r.cwd} · plan ${r.session.plan || "none"}`);
    },
  });
}
