---
name: plan-ticket
description: >-
  Turn a Linear ticket OR an ad-hoc task you describe in chat into a reviewable plain-English plan artifact BEFORE any code, then implement strictly within it and reconcile. Hard-gates on the user's sign-off so they stay the architect even in unfamiliar languages (e.g. Go). The north star is CONTAINMENT — the work produced stays as small and bounded as possible. Triggers on "/plan-ticket", "plan EVERY-####", "build a plan for <ticket>", "plan this: <task>", "implement the plan", "reconcile the plan".
---

# plan-ticket

Three-phase workflow. North star: **containment** — the surface area is a hard
boundary, and the artifact lets the user see and prove the work stayed small.

## Design principles (David's standing constraints — apply to EVERY plan)

These bind every plan and every decision point. When a plan or a D-option
violates one, say so explicitly and prefer the option that doesn't; when the
ticket itself pushes against one, flag it rather than absorb it silently.

1. **Simplest possible, smallest surface area, always.** The default answer is
   the least code that satisfies the ticket. Fewer files, fewer new
   abstractions, fewer moving parts. A bigger design needs a stated reason in
   the plan, not the reverse. This is the containment north star, restated as a
   design value, not just a boundary check.
2. **As little inheritance as possible.** Prefer composition, plain functions,
   and explicit wiring over class hierarchies, base classes, mixins, or
   deep type/interface inheritance. If a plan introduces an inheritance chain,
   call it out and justify it against a composition alternative.
3. **Align with existing patterns as far as possible.** New code should look
   like the code already around it — reuse the established helper, module shape,
   naming, and convention rather than introducing a parallel way to do the same
   thing. Before proposing a new mechanism, search for the existing one and
   prefer extending it. A deviation from an established pattern is never a
   silent default: record it in **Decided** with its justification, and only
   escalate to a decision point if following the pattern is genuinely
   contestable for the goal.

Surface these in the plan: the "surface area" section already proves #1; #2 and
#3 land in **Decided** one-liners (name the pattern followed, or the deviation
and why) — a D-block only where the goal truly doesn't imply the answer.

## Asking the user (blocking input)

When you need the user's blocking input mid-flow — an unresolved decision you
can't derive, a surface-area boundary you want to cross, approval to proceed —
**raise it with the `ask_user` tool, never in prose.** In the agent rail this
renders as an approval card with a "needs input" flag on the roster and scrolls
the plan buffer to the decision; a prose question surfaces nothing and the user
never sees it. Set `title` to the decision's heading **exactly as written in the
plan** (e.g. `D2: cursor start position`) so the plan scrolls to that line.

- Yes/no → `ask_user(kind="confirm", title, message)` → `approved`/`declined`.
- Pick one → `ask_user(kind="choice", title, message, options=[…])` → the choice.
- Free text → `ask_user(kind="input", title, message)` → the entry.

This does **not** change PLAN: decisions are still batch-presented in the
artifact for the user to resolve in neovim (do not `ask_user` per D-block during
PLAN). `ask_user` is for the interactive blocking points during `--go`/`--amend`.

Three artifacts, keyed to the plan, are the seam between this skill and the neovim
plugin (which renders the `.md` live and overlays step/file status). Everything is
markdown/JSON read in neovim — no HTML view, no browser. Never duplicate their
state elsewhere.

- `<plandir>/<key>.md` — the human artifact (source of truth). Includes the
  `## How it works` ASCII-tree section authored at FINALIZE.
- `<plandir>/<key>.progress.json` — machine state, read by the plugin (live-watch).
  Always exists from PLAN onward.
- `<plandir>/<key>.review.json` — produced by RECONCILE: hunk↔step correspondence,
  drift flags, verification results.

`<key>` is the plan's identity: a Linear ticket id (`EVERY-1234`) — the default — or,
for your own work, a short kebab-case slug of the task (`refactor-color-utils`). The
whole flow runs from any agent session (claude, or pi in the nvim rail) in any repo; no worktree or Linear required.
(In a lovable worktree the neovim plugin derives the key from the branch to auto-open
the plan; elsewhere, pass the key to `--finalize`/`--go`/`--reconcile` or open the
`.md` directly.)

**Plan location (`<plandir>`) — resolve once per run:**
- If `~/personal/notes/storage/` exists **AND is the real synced vault** — verify with
  `pgrep -f "notes-cli -watch" >/dev/null` (the sync watcher only runs on David's
  machine) → **`~/personal/notes/storage/plans/`**. The plan is then durable, synced,
  searchable (`notes-memory`), and referenceable across cycles. `mkdir -p` the plans
  subdir. **Never `mkdir -p` the vault root itself**: on a VM/sandbox a bare directory
  at that path is a PHANTOM — plans written there are invisible to David's nvim and
  strand on the box (this happened; the pull-back was manual).
- Otherwise (VM worker, lovbox sandbox — no watcher) → **`<repo-root>/.plans/`**, gitignored via
  `"$(git rev-parse --git-common-dir)"/info/exclude` (local-only, never committed).
  Use `--git-common-dir`, NOT a literal `.git/info/exclude`: in a git WORKTREE
  `.git` is a *file* pointing at the real gitdir, so the literal path does not
  exist and the write fails. Lovbox work is always in a worktree.

Surface-area paths in the plan stay repo-relative; `--go`/`--reconcile` run from the
worktree and resolve them against the current checkout, wherever the plan lives.

`progress.json` schema:
```json
{
  "ticket": "EVERY-1234",
  "branch": "<git branch --show-current>",
  "session": "<registered agentd session name, or empty outside agentd>",
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
2. Resolve the executing session with `agent_whoami` when that tool is available.
   In a registered agentd session, immediately call `agent_set_plan` with the derived
   key; this makes `new plan…` auto-bind as soon as plan-ticket derives its slug.
   Outside agentd, leave the progress `session` field empty and continue normally.
3. Spawn **read-only** Explore agents to map where this lands and what exists
   nearby. NO code is written in this or any planning step.
4. Fill `~/nixos/dotfiles/ai/skills/plan-ticket/template.md` COMPLETELY → `<plandir>/<key>.md`
   (substitute `{{TICKET}}` = the key — ticket id or ad-hoc slug; `{{TITLE}}`;
   `{{DATE}}` = `date -u +%Y-%m-%dT%H:%MZ`; `{{BRANCH}}` = `git branch --show-current`).
   Every section filled: the shape, the
   flow with ◆ new steps, decision points (options + recommendation), surface area +
   tree, verification, out of scope.
5. Write `<plandir>/<key>.progress.json` (`phase: "draft"`, branch, resolved
   `session`, `planned[]` from the surface area, all `status: "pending"`; `flow[]`
   seeded from the `◆` steps — one entry each, in flow order, all `status: "pending"`).
6. **Open it in neovim** so the user drives the rest from there: run
   `plan-open "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" <plandir>/<key>.md`.
   `plan-open` deterministically runs `mdformat --wrap 80` first and refuses to continue
   if formatting fails. It then pops the plan up in an nvim window, or no-ops if one's already in the
   repo or there's no GUI). The lifecycle keybinds in that nvim dispatch `--finalize`/
   `--go`/`--reconcile` back to THIS agent session (via wt-send, which routes to the pi rail session or a claude TUI), so keep it open.
7. **STOP.** Print only a one-line pointer to the artifact path. The user manages it
   from there in neovim — editing steps, resolving decisions, approving. Do not
   iterate on the plan in chat. `--go` runs only after the plan is approved
   (status `planned`) in the editor.

Quality bar:
- **The shape**: dumb-simple, five-second read.
- **The flow**: show existing steps for context and mark NEW work with ◆; this is
  how the user sees the work is minimal and where it slots in.
- **Decision points**: FLOW forks only — how the thing should behave for its
  user, where the ticket + house rules genuinely underdetermine the answer.
  Before writing a D-block, apply the **derivability test**: given what David
  said he wants, is one option obviously it? If yes, decide it yourself and
  record it under **Decided** (visible, vetoable, non-blocking). Code-level
  choices — which helper, where code lives, naming, extend-vs-copy, error
  handling shape — are always derivable: decide, never ask. Zero D-blocks in
  a plan whose path is implied is correct, not lazy; a manufactured decision
  is as much a defect as a hidden one.
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
   governs instead of leaving a standalone line. **Decided** entries are already
   directives — keep them as-is (any the user edited count as their call).
3. **Strip the Q&A.** Delete every `> ❓` question and `> 💬` answer — they were
   review scaffolding; the conclusion the user acted on already lives in the
   decision / the directives they edited into the plan.
4. Result: a directive plan — shape, flow (decisions baked in), final surface area,
   verification, out of scope — no menus, questions, or markers. This is what
   `--go` implements literally.
5. **Author the "How it works" section** — append a `## How it works` section to
   the plan `.md` (before `## Amendments`/`## Reconciliation`) showing *how the
   planned change works*, as a **plain-text ASCII tree inside a fenced ` ```text `
   block** (monospace, so the tree aligns; no HTML, no separate file). Shape it to
   the change — data-flow pipeline, before/after, state machine, sequence. Format:
   - **Lanes** = plain-text group headers at column 0 (e.g. `resolve`, `route`,
     `render`, or `backend`/`transport`/`frontend`).
   - **Nodes** = indented `◆N  <plain-english title>  ·  <repo-relative-path>`,
     where `◆N` ties the node to the `◆` flow step it realizes (1-based, md order;
     several nodes may share a step). Under each node, an indented full sentence in
     **plain English for someone who hasn't read the plan** — what happens here and
     why it matters, never a compressed jargon chain.
   - **Arrows** = an indented `↓ <what flows here>` line between nodes.

   ```text
   resolve
     ◆1  editor picks which view opens  ·  web/shared/lib/views/providers/ViewProvider.tsx
           the project's type decides whether the DS canvas or the general canvas loads
         ↓ project_type = "library"
   route
     ◆2  library → its own Canvas home  ·  web/modules/editor/DesktopContent.tsx
           library projects mount the authoring canvas + components rail as their home view
         ↓ mounts authoring canvas + rail
   render
     ◆3  authoring canvas + rail        ·  web/modules/design-system/home/DesignSystemCanvasView.tsx
           the new view wrapper composes the existing center + rail and unmounts on view switch
   ```

   Label real files/symbols from the surface area. Together the nodes must tell the
   change's whole story end to end. Live step status is NOT baked in here — it lives
   in the flow list + the neovim plan panel/changes-view; the `◆N` tags let the
   reader cross-reference. Tag every `◆` step with a node so the story is complete.
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
5. If the added scope changes how the change works, refresh the plan's
   `## How it works` ASCII-tree section to match (same rules as FINALIZE).
6. Reset the review gate so the user re-approves the expanded plan before `--go`
   continues: set `> Status:` to `draft` if you added a decision (the editor routes
   that to resolve → approve), else `amended` (routes to re-finalize). STOP — print
   only the artifact path. The user's plan buffer opens/reloads automatically; they
   review the additions and re-approve in neovim. `--go` continues into the expanded
   boundary only after that.

## PHASE 2 — IMPLEMENT (`--go`)

0. The plan renders live in neovim (the plan-nvim plugin watches the `.md` +
   `progress.json` and overlays step/file status as you work) — nothing to open.
   Best-effort ensure it's up: `plan-open "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" <plandir>/<key>.md`.
1. Read `<plandir>/<key>.md` (normally already `--finalize`d into clean
   directives); honor the user's edits — their text wins.
2. Refuse to start if any **Your call:** is `(unresolved)`; list them and stop.
2a. If progress `session` is non-empty, call `agent_whoami` and refuse unless both
   the session name matches that field and its current roster binding is this plan's
   key. Rebinding a long-lived session to another task immediately prevents the old
   plan from being executed there. Outside agentd (`session` empty), skip this check.
2b. **If the plan's `> Status:` is not `finalized`** (draft/amended with all
   decisions resolved), run the FINALIZE phase first — bake directives, author the
   `## How it works` section, set the status — then continue into implementation.
   The steps are ordered; skipping finalize silently loses the section and leaves
   A/B menus in the spec.
3. Implement strictly within the surface area. Before touching any file NOT in the
   surface-area list, STOP and ask via `ask_user` (`kind="confirm"`, `title` = the
   file/decision) — record approved additions under `unplanned[]` with a why.
4. Keep `<plandir>/<key>.progress.json` current as you work: `phase: "implementing"`,
   and drive BOTH axes:
   - **`flow[]` (the headline)** — flip each step `pending → active → done` as you start
     and finish it. This is what the panel counts (steps done / total), so it MUST track
     reality tightly — a stale or scrambled `flow[]` makes the dashboard lie. Rules,
     non-negotiable:
       - **Exactly ONE step is `active` at any time.** Before you mark the next step
         `active`, flip the current one to `done`. Never leave two steps `active`.
       - **Write the file at each transition, immediately** — the moment you finish a
         step and the moment you start the next. NOT batched at the end of the turn;
         batching is exactly what makes the panel sit at 1/7 while you're really on 4.
       - **Monotonic**: never mark a later step `done` while an earlier one is still
         `pending`/`active`. Work and complete steps in flow order; if you genuinely
         must do them out of order, still keep at most one `active` and don't skip the
         earlier ones' `done` flips.
       - On the final step, flip it `done` (not left `active`) before you finish.
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
3b. **Budget + simplicity pass — the slop check.** Compare `git diff --shortstat`
   against the plan's declared budget: over 1.5× is a STOP, reported as what must
   SHRINK (never a raised budget). Then answer the plan's Simplicity pass with
   evidence, and act on it in the same run rather than reporting it:
   - every new exported symbol → name its production caller; no caller ⇒ inline or
     delete it, tests included
   - every new file → one sentence on why it couldn't live in an existing file
   - any `*Ref`/cache/pending-queue mirroring server or DOM state → why it can't be
     read at the point of use
   - any test asserting a helper's internals ⇒ rewrite through the public entry point
   - anything needing a dev-only flag or override ⇒ not done; say so plainly
   Correct-but-oversized is a finding. A diff can pass every test and still be slop:
   EVERY-2739/2741/3064 shipped +970 lines, 97 review threads and a dead exported
   helper for a feature whose answer was "store w/h at snapshot time".
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
   and the plugin read the final state from the artifact itself. After those writes
   succeed, call `agent_set_plan` with an empty key when available. A session binding
   means active work; the reconciled artifact remains the historical record.
7. **Check off tests as they're run (ongoing, after reconcile).** As the user works
   through the pending `MT#` (manual) checks, update that item's `result` in
   `<key>.review.json` (`pending` → `pass`/`fail`); the panel reflects it live. Infer
   from the conversation — if the user says a check works, or a screenshot/description
   clearly shows it passing or failing, flip the matching item and tell them which
   `MT#` you flipped and why. If it's ambiguous, ask rather than guess. Never mark
   `pass` without evidence.
