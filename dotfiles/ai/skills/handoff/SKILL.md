---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session / agent focus on?"
disable-model-invocation: true
---

Write a handoff document summarising the current conversation so a fresh agent can
continue the work WITHOUT the original transcript.

## Where to save (vault-first, so it can reach another agent)

- If `~/personal/notes/storage/` exists (the vault), save to
  `~/personal/notes/storage/handoffs/<YYYY-MM-DDTHH-MM>-<slug>.md` (`mkdir -p` it).
  The vault is synced (`notes-cli -watch`) and readable by every local agent, so a
  handoff there actually reaches another session. A `/tmp` file does NOT — each pi
  session / sandbox has its own temp dir, so a co-worker agent can't read it.
- Otherwise (lovbox sandbox, no vault), save to the OS temporary directory.

## What to include

- A **suggested skills** section listing the skills the next agent should invoke.
- The **next-session goal** — if the user passed arguments, treat them as the focus and
  tailor the doc to them.
- Enough live state (decisions made, what's done, what's pending, gotchas) that a fresh
  agent can pick up cold.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues,
commits, diffs, notes-vault entries). Reference them by path or URL instead.

Redact any sensitive information: API keys, passwords, tokens, or PII.

## Deliver to another agent (agent-to-agent)

The handoff doc is the payload; **agentd is the transport**. After writing it, hand it
off through the existing orchestrator→worker channel — pass the PATH, never the content
(the receiving agent reads the synced file itself):

- To an EXISTING roster agent: `agent send <ref> "Pick up the handoff at <path> and continue."`
  (`<ref>` = session name / id / cwd; lands at the target's next idle.) Use `agent steer`
  instead only if it must interrupt a running turn.
- To a NEW agent for the work: `cockpit-spawn <name> "Read the handoff at <path> and continue."`
  (full worktree + devenv + rail tabs), or `agent spawn <dir> "…<path>…"` for an in-dir agent.

This is orchestrator-mediated only — never wire agent↔agent ping-pong.
