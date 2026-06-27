---
name: plan-ticket
description: Turn a Linear ticket into a reviewable plain-English plan artifact BEFORE any code, then implement strictly within it and reconcile. Hard-gates on the user's sign-off so they stay the architect even in unfamiliar languages (e.g. Go). The north star is CONTAINMENT — the work produced stays as small and bounded as possible. Triggers on "/plan-ticket", "plan EVERY-####", "build a plan for <ticket>", "implement the plan", "reconcile the plan".
---

# plan-ticket

Three-phase workflow. North star: **containment** — the surface area is a hard
boundary, and the artifact lets the user see and prove the work stayed small.

Two files, both keyed to the ticket, are the seam between this skill, the neovim
plugin, and the Quickshell board. Never duplicate their state elsewhere.

- `.plans/<ticket>.md` — the human artifact (source of truth). Authored by the user.
- `.plans/<ticket>.progress.json` — machine state, read by the plugin (live-watch)
  and Quickshell (cross-ticket progress board). Always exists from PLAN onward.
- `.plans/<ticket>.review.json` — produced by RECONCILE, read by the neovim review
  layer: hunk↔step correspondence, drift flags, and verification results.

Run from inside the target repo/worktree. `.plans/` is relative to repo root; on
first use add it to `.git/info/exclude` (local-only, never committed).

`progress.json` schema:
```json
{
  "ticket": "EVERY-1234",
  "branch": "<git branch --show-current>",
  "phase": "draft|planned|implementing|reconciled",
  "planned":   [{"file": "...", "action": "create|modify|touch", "status": "pending|touched|done"}],
  "unplanned": [{"file": "...", "why": "..."}],
  "updated_at": "<iso8601>"
}
```

## Phase selection
- no flag / `<ticket>` → **PLAN** (default)
- `--go` → **IMPLEMENT**
- `--reconcile` → **RECONCILE**

---

## PHASE 1 — PLAN (spit out the full plan, then hand off to neovim)

Generate the COMPLETE plan in one shot and write it out. Do NOT discuss it step by
step in chat — the user manages, edits, and approves the plan inside neovim, not by
conversing with the agent. Your job here is the best full draft you can produce.

1. Resolve the ticket id (e.g. `EVERY-1234`) and pull it with the Linear MCP
   (`get_issue`). Pull adjacent context (Company Brain `search`) only if useful.
2. Spawn **read-only** Explore agents to map where this lands and what exists
   nearby. NO code is written in this or any planning step.
3. Fill `~/.claude/skills/plan-ticket/template.md` COMPLETELY → `.plans/<ticket>.md`
   (substitute `{{TICKET}}`, `{{TITLE}}`, `{{DATE}}` = `date -u +%Y-%m-%dT%H:%MZ`,
   `{{BRANCH}}` = `git branch --show-current`). Every section filled: the shape, the
   flow with ◆ new steps, decision points (options + recommendation), surface area +
   tree, verification, out of scope.
4. Write `.plans/<ticket>.progress.json` (`phase: "draft"`, branch, `planned[]` from
   the surface area, all `status: "pending"`).
5. **STOP.** Print only a one-line pointer to the artifact path. The user manages it
   from there in neovim — editing steps, resolving decisions, approving. Do not
   iterate on the plan in chat. `--go` runs only after the plan is approved
   (status `planned`) in the editor.

Quality bar:
- **The shape**: dumb-simple, five-second read.
- **The flow**: show existing steps for context and mark NEW work with ◆; this is
  how the user sees the work is minimal and where it slots in.
- **Decision points**: real forks with options + recommendation. None = you're
  hiding the architecture; find them.
- **Surface area**: every file you intend to create/modify/touch, one-line why.
  This is the containment boundary — keep it tight.

## PHASE 2 — IMPLEMENT (`--go`)

1. Read `.plans/<ticket>.md`; honor the user's edits — their text wins.
2. Refuse to start if any **Your call:** is `(unresolved)`; list them and stop.
3. Implement strictly within the surface area. Before touching any file NOT in the
   table, STOP and ask — record approved additions under `unplanned[]` with a why.
4. Keep `progress.json` current as you work: `phase: "implementing"`, flip each
   planned file `pending → touched → done`. This is also the plugin's live-watch feed.
5. Run the verification strategy. Report results plainly.

## PHASE 3 — RECONCILE (`--reconcile`)

Answers two questions for the user: did reality match the plan, and does it work.
The user reviews against the plan, not against raw Go — so correspondence and
verification are the product here, not per-line explanation.

1. Read `progress.json` and the actual git changes (`git status`, `git diff`).
2. **Correspondence (both directions):**
   - diff → plan: map each changed file/hunk to the plan step (`◆`) or decision
     (`D`) it implements.
   - plan → diff: check every planned step produced a change. A planned step with
     no corresponding change is flagged `missing` (silently dropped work).
3. **Drift:** any file/hunk outside the surface-area boundary, or any change that
   maps to no step, is flagged. This is the containment check.
4. **Verification:** run each item from the plan's Verification strategy that has a
   command (tests, build, lint); record `pass|fail`. Mark manual checks `pending`.
   Never claim a check passed without running it.
5. Emit `.plans/<ticket>.review.json`:
   ```json
   {
     "correspondence": [{"step": "◆2", "files": ["service.go"], "hunks": ["service.go:40-58"], "status": "done|missing"}],
     "drift":          [{"file": "x.go", "hunk": "x.go:10-22", "why": "not in surface area"}],
     "verification":   [{"check": "unit test X", "command": "...", "result": "pass|fail|pending"}]
   }
   ```
6. Fill the artifact's **Reconciliation** section (human summary: planned vs touched,
   missing steps, drift verdict, verification results) and set `phase: "reconciled"`.
