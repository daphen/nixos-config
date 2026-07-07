---
name: plan-ticket
description: Turn a Linear ticket OR an ad-hoc task you describe in chat into a reviewable plain-English plan artifact BEFORE any code, then implement strictly within it and reconcile. Hard-gates on the user's sign-off so they stay the architect even in unfamiliar languages (e.g. Go). The north star is CONTAINMENT — the work produced stays as small and bounded as possible. Triggers on "/plan-ticket", "plan EVERY-####", "build a plan for <ticket>", "plan this: <task>", "implement the plan", "reconcile the plan".
---

# plan-ticket

Three-phase workflow. North star: **containment** — the surface area is a hard
boundary, and the artifact lets the user see and prove the work stayed small.

Three artifacts, keyed to the plan, are the seam between this skill, the neovim
plugin, and the live plan view (plan-view.py, opened as an app window on --go).
Never duplicate their state elsewhere.

- `<plandir>/<key>.md` — the human artifact (source of truth).
- `<plandir>/<key>.progress.json` — machine state, read by the plugin (live-watch)
  and the plan view. Always exists from PLAN onward.
- `<plandir>/<key>.review.json` — produced by RECONCILE: hunk↔step correspondence,
  drift flags, verification results.
- `<plandir>/<key>.diagram.html` — "How it works" fragment for the plan view,
  written at FINALIZE (see there). Optional; the view shows a placeholder without it.

`<key>` is the plan's identity: a Linear ticket id (`EVERY-1234`) — the default — or,
for your own work, a short kebab-case slug of the task (`refactor-color-utils`). The
whole flow runs from any claude session in any repo; no worktree or Linear required.
(In a lovable worktree the neovim plugin derives the key from the branch to auto-open
the plan; elsewhere, pass the key to `--finalize`/`--go`/`--reconcile` or open the
`.md` directly.)

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
  "flow":      [{"step": "one line matching a ◆ step in the plan", "status": "pending|active|done"}],
  "planned":   [{"file": "...", "action": "create|modify|touch", "status": "pending|touched|done", "note": "optional one line: what you did, or why no change was needed"}],
  "unplanned": [{"file": "...", "why": "..."}],
  "updated_at": "<iso8601>",
  "amended_at": "<iso8601, set by --amend>"
}
```

`flow[]` is the headline progress axis — one entry per `◆` step in the plan, in order.
The plugin's panel and statusline count **steps done / total steps** off it (the
conceptual unit of work), and falls back to the `planned[]` file count only for plans
written before `flow[]` existed. `planned[]` remains the containment boundary (drift is
checked against it), not the progress metric. Keep `flow[]` entries aligned 1:1 with the
`◆` steps in the `.md`, in the same order.

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

1. **Identify the work and the key.** Two ways in:
   - **Linear ticket** (`EVERY-1234`) → pull it with the Linear MCP (`get_issue`);
     the key is the ticket id. Pull adjacent context (Company Brain `search`) if useful.
   - **Ad-hoc task** (free text — your own work, no ticket) → the description IS the
     task; skip Linear. The key is a short kebab-case slug you derive from the task
     ("Refactor the color utils" → `refactor-color-utils`). Works from any repo/cwd —
     no worktree needed. (If you happen to be on a matching `daphen/<name>` worktree
     branch, use that short name so the neovim plugin auto-opens it.)
2. Spawn **read-only** Explore agents to map where this lands and what exists
   nearby. NO code is written in this or any planning step.
3. Fill `~/.claude/skills/plan-ticket/template.md` COMPLETELY → `<plandir>/<key>.md`
   (substitute `{{TICKET}}` = the key — ticket id or ad-hoc slug; `{{TITLE}}`;
   `{{DATE}}` = `date -u +%Y-%m-%dT%H:%MZ`; `{{BRANCH}}` = `git branch --show-current`).
   Every section filled: the shape, the
   flow with ◆ new steps, decision points (options + recommendation), surface area +
   tree, verification, out of scope.
4. Write `<plandir>/<key>.progress.json` (`phase: "draft"`, branch, `planned[]` from
   the surface area, all `status: "pending"`; `flow[]` seeded from the `◆` steps — one
   entry each, in flow order, all `status: "pending"`).
5. **Open it in neovim** so the user drives the rest from there: run
   `plan-open "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" <plandir>/<key>.md`
   (best-effort — pops the plan up in an nvim window, no-ops if one's already in the
   repo or there's no GUI). The lifecycle keybinds in that nvim dispatch `--finalize`/
   `--go`/`--reconcile` back to THIS claude session, so keep it open.
6. **STOP.** Print only a one-line pointer to the artifact path. The user manages it
   from there in neovim — editing steps, resolving decisions, approving. Do not
   iterate on the plan in chat. `--go` runs only after the plan is approved
   (status `planned`) in the editor.

Quality bar:
- **The shape**: dumb-simple, five-second read.
- **The flow**: show existing steps for context and mark NEW work with ◆; this is
  how the user sees the work is minimal and where it slots in.
- **Decision points**: real forks with options + recommendation. None = you're
  hiding the architecture; find them.
- **Surface area**: every file you intend to create/modify/touch, one-line why,
  listed in flow order (the order their step runs). This is the containment
  boundary — keep it tight.

## PHASE 1.5 — FINALIZE (`--finalize`)

Turn the reviewed plan into a clean execution spec — run after the decisions are
resolved, before `--go`. Read-only on code; rewrites the plan artifact in place.

1. Read `<plandir>/<key>.md`. Refuse if any **Your call:** is still
   `(unresolved)` — list them and stop (can't bake an open decision).
2. **Bake each decision into a directive.** Replace every `### D#` block with a
   one-line resolved instruction stating the chosen option (carry the rationale,
   trimmed). Drop the A/B options, the recommendation, and the `Your call:` line.
   Where cleaner, fold the directive into the flow step / surface-area item it
   governs instead of leaving a standalone line.
3. **Strip the Q&A.** Delete every `> ❓` question and `> 💬` answer — they were
   review scaffolding; the conclusion the user acted on already lives in the
   decision / the directives they edited into the plan.
4. Result: a directive plan — shape, flow (decisions baked in), final surface area,
   verification, out of scope — no menus, questions, or markers. This is what
   `--go` implements literally.
5. **Author the diagram** → `<plandir>/<key>.diagram.html`: a raw HTML fragment
   showing *how the planned change works*, in the shape that fits it — data-flow
   pipeline, before/after, state machine, sequence. Same component vocabulary as
   review-pr's centrepiece (classes live in the shared ui.css): `.lane` (neutral
   surface; `.be`/`.tr`/`.fe` are semantic-only markers) with a `.lane-tag`,
   `.node` (inner `.file` for the real path, `.sub` for a one-liner), `.arrow`
   (`.big` between lanes), `.split` for parallel nodes. Label real files/symbols
   from the surface area; colours only via `--rv-*` vars, never hex. Where a node
   maps to one surface file, add `data-file="<repo-relative>"` so `o` opens it.
   Node `.sub` text is **plain English for someone who hasn't read the plan** —
   a full sentence saying what happens at this node and why it matters, never a
   compressed jargon chain ("D1 probe: passthrough verified"). Together the
   nodes must tell the change's whole story end to end. Tag every node that
   realizes a `◆` step with `data-step="N"` (1-based, md order; several nodes
   may share a step) — **the diagram IS the flow view**: tagged nodes carry the
   step's live status dot and its full plan text as Enter-expandable detail,
   and the separate flow list only renders for steps the diagram doesn't tag
   (or before the diagram exists). Tag every step or its progress hides.
6. Set the plan's `> Status:` line to `finalized` (so the editor knows it's ready
   for `--go`). Leave `progress.json` otherwise unchanged.

## PHASE 1.75 — AMEND (`--amend`)

Scope changed mid-ticket: fold new work into the plan, on purpose and visibly. This
is the deliberate-growth path — distinct from `unplanned[]` (a boundary crossed under
pressure during `--go`). Runnable any time after PLAN. The prompt body (if any) is the
new scope to add; also honor any manual edits the user already made to the artifact.

1. Read `<plandir>/<key>.md`, `<plandir>/<key>.progress.json`, and the git diff
   so far. Never undo or re-plan completed work — preserve it.
2. Spawn read-only Explore agents only if the new scope needs mapping. NO code here.
3. Update the plan `.md` — the human source of truth. Do NOT record the increment
   only in `progress.json` or the chat; the artifact itself MUST show it:
   - **Surface area**: add a list item (`- **action** ` + `` `path` `` + a short why
     beneath) for EVERY new file and bump the `*New: N · Modified: N · Touched: N*`
     count line. This list IS the containment boundary — a file not in it gets flagged
     as drift at `--reconcile`. Don't rewrite or drop existing items.
   - **Flow**: add `◆` steps for the new work.
   - **Decision**: if the new scope forks, add a `### D#` block (re-opens the gate).
   - **Amendments**: append one line — `<date>: +<what> — <why>`. Add the
     `## Amendments` heading (before `## Reconciliation`) if the plan predates it.
4. Update `progress.json` to MATCH the surface-area list — the two must list the SAME
   files. Append the new files to `planned[]` (`status: pending`); KEEP every existing
   entry, including deliberately-skipped ones (`pending` + note — never drop them);
   append a `flow[]` entry (`status: pending`) for each new `◆` step, KEEPING the
   existing entries and their statuses (finished steps stay `done`); set `amended_at`;
   leave `phase` as is (work already done stays done).
5. If the added scope changes how the change works, refresh
   `<plandir>/<key>.diagram.html` to match (same component rules as FINALIZE).
6. Reset the review gate so the user re-approves the expanded plan before `--go`
   continues: set `> Status:` to `draft` if you added a decision (the editor routes
   that to resolve → approve), else `amended` (routes to re-finalize). STOP — print
   only the artifact path. The user's plan buffer opens/reloads automatically; they
   review the additions and re-approve in neovim. `--go` continues into the expanded
   boundary only after that.

## PHASE 2 — IMPLEMENT (`--go`)

0. FIRST, open the live plan view so the user watches the flow tick:
   `python3 ~/.claude/skills/plan-ticket/plan-view.py <key> --plandir <plandir> --open`
   Idempotent — reuses the running server (port 8746); the page hot-reloads
   whenever `progress.json`/`review.json` change.
1. Read `<plandir>/<key>.md` (normally already `--finalize`d into clean
   directives); honor the user's edits — their text wins.
2. Refuse to start if any **Your call:** is `(unresolved)`; list them and stop.
2b. **If the plan's `> Status:` is not `finalized`** (draft/amended with all
   decisions resolved), run the FINALIZE phase first — bake directives, author
   the diagram, set the status — then continue into implementation. The steps
   are ordered; skipping finalize silently loses the diagram and leaves A/B
   menus in the spec.
3. Implement strictly within the surface area. Before touching any file NOT in the
   surface-area list, STOP and ask — record approved additions under `unplanned[]` with a why.
4. Keep `<plandir>/<key>.progress.json` current as you work: `phase: "implementing"`,
   and drive BOTH axes:
   - **`flow[]` (the headline)** — flip each step `pending → active → done` as you start
     and finish it. `active` when you're working it, `done` when that conceptual step is
     complete. This is what the panel counts (steps done / total).
   - **`planned[]` (containment)** — flip each file `pending → touched → done` with a
     one-line `note` (what you changed, or why a planned file needed no change — it stays
     `pending` with the note, rendered as a deliberate skip).
   Both feed the plugin's live-watch; keep them in sync as you go.
5. Run the verification strategy. Report results plainly — AND persist the automated
   results so the panel shows them live, without waiting for `--reconcile`: write
   `<plandir>/<key>.review.json` with a `verification[]` array (schema below), each
   AT# item (one with a `command`) recorded `pass|fail` as you run it; leave the MT#
   (command-less, manual) items `pending`. Create the file if absent; it's fine that
   `correspondence`/`drift` stay empty until `--reconcile` fills them. Never mark an AT#
   `pass` without actually running its command.

## PHASE 3 — RECONCILE (`--reconcile`)

Answers two questions for the user: did reality match the plan, and does it work.
The user reviews against the plan, not against raw Go — so correspondence and
verification are the product here, not per-line explanation.

1. Read `<plandir>/<key>.progress.json` and the actual git changes (`git status`, `git diff`).
2. **Correspondence (both directions):**
   - diff → plan: map each changed file/hunk to the plan step (`◆`) or decision
     (`D`) it implements.
   - plan → diff: check every planned step produced a change. A planned step with
     no corresponding change is flagged `missing` (silently dropped work).
3. **Drift:** any file/hunk outside the surface-area boundary, or any change that
   maps to no step, is flagged. This is the containment check.
4. **Verification → the test checklist.** The `verification[]` array IS the panel's
   checklist: items WITH a `command` render as `AT#` (automated), items without as
   `MT#` (manual). `--go` may have already written AT# results here; re-run every `AT#`
   (tests, build, lint) to confirm and record the final `pass|fail`, and preserve any
   MT# results the user has already reported. Leave the remaining `MT#` ones `pending` —
   those are the steps the user runs by hand. Never claim a check passed without running it.
5. Emit (or update, if `--go` already created it) `<plandir>/<key>.review.json`:
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
7. **Check off tests as they're run (ongoing, after reconcile).** As the user works
   through the pending `MT#` (manual) checks, update that item's `result` in
   `<key>.review.json` (`pending` → `pass`/`fail`); the panel reflects it live. Infer
   from the conversation — if the user says a check works, or a screenshot/description
   clearly shows it passing or failing, flip the matching item and tell them which
   `MT#` you flipped and why. If it's ambiguous, ask rather than guess. Never mark
   `pass` without evidence.
