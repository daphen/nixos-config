---
name: plan-ticket
description: Turn a Linear ticket into a reviewable plain-English plan artifact BEFORE any code, then implement strictly within it and reconcile. Hard-gates on the user's sign-off so they stay the architect even in unfamiliar languages (e.g. Go). The north star is CONTAINMENT — the work produced stays as small and bounded as possible. Triggers on "/plan-ticket", "plan EVERY-####", "build a plan for <ticket>", "implement the plan", "reconcile the plan".
---

# plan-ticket

Three-phase workflow. North star: **containment** — the surface area is a hard
boundary, and the artifact lets the user see and prove the work stayed small.

Three artifacts, keyed to the ticket, are the seam between this skill, the neovim
plugin, and the Quickshell board. Never duplicate their state elsewhere.

- `<plandir>/<ticket>.md` — the human artifact (source of truth).
- `<plandir>/<ticket>.progress.json` — machine state, read by the plugin (live-watch)
  and Quickshell. Always exists from PLAN onward.
- `<plandir>/<ticket>.review.json` — produced by RECONCILE: hunk↔step correspondence,
  drift flags, verification results.

**Plan location (`<plandir>`) — resolve once per run:**
- If `~/personal/notes/storage/` exists (local) → **`~/personal/notes/storage/plans/`**.
  The plan is then durable, synced (`notes-cli -watch`), searchable (`notes-memory`),
  and referenceable across cycles — it outlives the worktree, and the `/cycle` skill
  reads it. `mkdir -p` it.
- Otherwise (lovbox sandbox, no vault) → **`<repo-root>/.plans/`**, gitignored via
  `.git/info/exclude` (local-only, never committed).

Surface-area paths in the plan stay repo-relative; `--go`/`--reconcile` run from the
worktree and resolve them against the current checkout, wherever the plan lives.

`progress.json` schema:
```json
{
  "ticket": "EVERY-1234",
  "branch": "<git branch --show-current>",
  "phase": "draft|planned|implementing|reconciled",
  "planned":   [{"file": "...", "action": "create|modify|touch", "status": "pending|touched|done", "note": "optional one line: what you did, or why no change was needed"}],
  "unplanned": [{"file": "...", "why": "..."}],
  "updated_at": "<iso8601>",
  "amended_at": "<iso8601, set by --amend>"
}
```

## Phase selection
- no flag / `<ticket>` → **PLAN** (default)
- `--finalize` → **FINALIZE** (clean the reviewed plan into an execution spec)
- `--amend` → **AMEND** (fold new scope into the plan mid-ticket)
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
3. Fill `~/.claude/skills/plan-ticket/template.md` COMPLETELY → `<plandir>/<ticket>.md`
   (substitute `{{TICKET}}`, `{{TITLE}}`, `{{DATE}}` = `date -u +%Y-%m-%dT%H:%MZ`,
   `{{BRANCH}}` = `git branch --show-current`). Every section filled: the shape, the
   flow with ◆ new steps, decision points (options + recommendation), surface area +
   tree, verification, out of scope.
4. Write `<plandir>/<ticket>.progress.json` (`phase: "draft"`, branch, `planned[]` from
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

## PHASE 1.5 — FINALIZE (`--finalize`)

Turn the reviewed plan into a clean execution spec — run after the decisions are
resolved, before `--go`. Read-only on code; rewrites the plan artifact in place.

1. Read `<plandir>/<ticket>.md`. Refuse if any **Your call:** is still
   `(unresolved)` — list them and stop (can't bake an open decision).
2. **Bake each decision into a directive.** Replace every `### D#` block with a
   one-line resolved instruction stating the chosen option (carry the rationale,
   trimmed). Drop the A/B options, the recommendation, and the `Your call:` line.
   Where cleaner, fold the directive into the flow step / surface-area row it
   governs instead of leaving a standalone line.
3. **Fold notes in.** Each `> 📝` note becomes an instruction on the step/file it
   sits under; remove the `📝` marker.
4. **Strip the Q&A.** Delete every `> ❓` question and `> 💬` answer — they were
   review scaffolding; the conclusion the user acted on already lives in the
   decision / instruction.
5. Result: a directive plan — shape, flow (decisions baked in), final surface area,
   verification, out of scope — no menus, questions, or markers. This is what
   `--go` implements literally.
6. Set the plan's `> Status:` line to `finalized` (so the editor knows it's ready
   for `--go`). Leave `progress.json` otherwise unchanged.

## PHASE 1.75 — AMEND (`--amend`)

Scope changed mid-ticket: fold new work into the plan, on purpose and visibly. This
is the deliberate-growth path — distinct from `unplanned[]` (a boundary crossed under
pressure during `--go`). Runnable any time after PLAN. The prompt body (if any) is the
new scope to add; also honor any manual edits the user already made to the artifact.

1. Read `<plandir>/<ticket>.md`, `<plandir>/<ticket>.progress.json`, and the git diff
   so far. Never undo or re-plan completed work — preserve it.
2. Spawn read-only Explore agents only if the new scope needs mapping. NO code here.
3. Update the plan `.md` — the human source of truth. Do NOT record the increment
   only in `progress.json` or the chat; the artifact itself MUST show it:
   - **Surface area**: add a table row for EVERY new file (create/modify/touch) and
     bump the `*New: N · Modified: N · Touched: N*` count line. This table IS the
     containment boundary — a file not in it gets flagged as drift at `--reconcile`.
     Don't rewrite or drop existing rows.
   - **Flow**: add `◆` steps for the new work.
   - **Decision**: if the new scope forks, add a `### D#` block (re-opens the gate).
   - **Amendments**: append one line — `<date>: +<what> — <why>`. Add the
     `## Amendments` heading (before `## Reconciliation`) if the plan predates it.
4. Update `progress.json` to MATCH the surface-area table — the two must list the SAME
   files. Append the new files to `planned[]` (`status: pending`); KEEP every existing
   entry, including deliberately-skipped ones (`pending` + note — never drop them);
   set `amended_at`; leave `phase` as is (work already done stays done).
5. Reset the review gate so the user re-approves the expanded plan before `--go`
   continues: set `> Status:` to `draft` if you added a decision (the editor routes
   that to resolve → approve), else `amended` (routes to re-finalize). STOP — print
   only the artifact path. The user's plan buffer opens/reloads automatically; they
   review the additions and re-approve in neovim. `--go` continues into the expanded
   boundary only after that.

## PHASE 2 — IMPLEMENT (`--go`)

1. Read `<plandir>/<ticket>.md` (normally already `--finalize`d into clean
   directives); honor the user's edits — their text wins.
2. Refuse to start if any **Your call:** is `(unresolved)`; list them and stop.
3. Implement strictly within the surface area. Before touching any file NOT in the
   table, STOP and ask — record approved additions under `unplanned[]` with a why.
4. Keep `<plandir>/<ticket>.progress.json` current as you work: `phase: "implementing"`,
   flip each planned file `pending → touched → done`. Add a one-line `note` per file —
   what you changed, or why a planned file needed no change (it stays `pending` with the
   note, which the plugin renders as a deliberate skip). This is the plugin's live-watch feed.
5. Run the verification strategy. Report results plainly.

## PHASE 3 — RECONCILE (`--reconcile`)

Answers two questions for the user: did reality match the plan, and does it work.
The user reviews against the plan, not against raw Go — so correspondence and
verification are the product here, not per-line explanation.

1. Read `<plandir>/<ticket>.progress.json` and the actual git changes (`git status`, `git diff`).
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
5. Emit `<plandir>/<ticket>.review.json`:
   ```json
   {
     "correspondence": [{"step": "◆2", "files": ["service.go"], "hunks": ["service.go:40-58"], "status": "done|missing"}],
     "drift":          [{"file": "x.go", "hunk": "x.go:10-22", "why": "not in surface area"}],
     "verification":   [{"check": "unit test X", "command": "...", "result": "pass|fail|pending"}]
   }
   ```
6. Fill the artifact's **Reconciliation** section (human summary: planned vs touched,
   missing steps, drift verdict, verification results), set `progress.json` `phase:
   "reconciled"`, **and flip the plan's `> Status:` line to `reconciled`** so `/cycle`
   and the plugin read the final state from the artifact itself.
