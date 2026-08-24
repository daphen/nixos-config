# handoff

Write a handoff document summarising the current session's state so a fresh
agent (or an orchestrator on another host) can continue the work WITHOUT this
transcript. Invoked as `/skill:handoff [focus]` — treat any argument as the
next-session goal and tailor the document to it.

## Where to save

- If `~/personal/notes/storage/` exists (the vault):
  `~/personal/notes/storage/handoffs/<YYYY-MM-DDTHH-MM>-<slug>.md` (mkdir -p).
  The vault syncs, so any local agent can read it.
- Otherwise (VM/sandbox, no vault): `<repo-root>/.plans/handoffs/<same>.md`,
  and ALSO include the full document in your reply — the file may not be
  reachable from the receiving side.

## What to include (all sections, terse but complete)

1. **Goal state** — the standing goal verbatim and how far along it is.
2. **Workers/sessions** — each one: name, exact current state, last VERIFIED
   evidence (not claims), and what it was last told.
3. **Decisions in force** — approvals given, constraints, things explicitly
   forbidden. These bind the successor.
4. **Pending actions with owners** — worker / orchestrator / David.
5. **Gotchas** — anything a successor would trip on (stale caches, half-done
   migrations, credentials quirks).

Do not duplicate what other artifacts already record (plans, progress.json,
commits) — reference them by path instead. Redact secrets: never write key
material, tokens, or passwords into a handoff.

## Delivery

The document is the payload; agentd is the transport. To hand to an EXISTING
session: `agent_send <ref> "Pick up the handoff at <path> and continue."`
(pass the PATH when the receiver shares the filesystem; paste the CONTENT
inline when it does not — a VM cannot read the vault). Never assume the
receiver saw this transcript.
