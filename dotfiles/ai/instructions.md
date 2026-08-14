# Worktree Management

Use `wt` (worktrunk) for all worktree operations instead of raw `git worktree` commands:

- `wt switch --create <branch>` to create a new worktree/branch
- `wt switch <branch>` to switch to an existing worktree
- `wt list` to show worktrees and their status
- `wt merge` to squash, rebase, fast-forward merge, and clean up
- `wt remove` to remove a worktree
- `wt step commit` to commit with LLM-generated message
- `wt step copy-ignored` to copy gitignored files between worktrees

## Cockpit contexts (proart-only)

The workspace-per-stack flow (ws-createwt, per-ticket niri workspaces) is
RETIRED on proart. Everything lives on one `lovable` workspace — the
cockpit: three fixed kitty windows (agent, nvim, devenv) plus the work
browser, where each worktree is a *context* = one tab in each window.

When the user asks for a new worktree on proart, use
`~/.config/niri/scripts/cockpit-add <name>`. It creates the branch +
worktree via wt (`daphen/<name>` off fresh origin/main, at
`~/work/lovable.daphen-<name>`), opens one tab per cockpit window (claude
resumes the newest non-empty session for that worktree, devenv boots the
wt slice), registers the context for crash-restore, and switches to it.
No workspace is claimed and no windows spawn, so no confirmation needed —
but the cockpit windows must exist (`cockpit-open` is idempotent;
`cockpit-restore` rebuilds everything after a crash).

Naming: the context name IS the branch short-name and is JUST the ticket
id, lowercased — no title slug. The full ticket id must be present (Linear
auto-links on the identifier in the branch name, case-insensitive, and
GitHub closes the issue from the PR body — the title slug was only ever for
human readability and is dropped). For EVERY-1234:
- context name / worktree: `every-1234`
- git branch: `daphen/every-1234`
- `main` is a special context: the primary checkout, runs `devenv deps`.

Switching: `cockpit-switch <name>` (users press Super+T). Closing: Ctrl+W
in the picker closes the tabs and keeps the dir; `wt remove daphen/<name>`
deletes it. The old ws-* scripts remain on disk but are unbound — don't
reach for them unless the user explicitly asks.

## Lovable-on-Lovable sandboxes (proart-only)

For tasks that should run in a REMOTE Lovable sandbox instead of locally,
the flow is two steps because **project creation is now Castle-gated**
(requires a browser-minted `X-Castle-Request-Token` that CLI scripts
can't produce):

```
ws-newlol                              # opens lovable.dev in work browser
# in the browser: workspace → New Project → toggle LoL → submit
# copy the resulting URL
ws-createlovbox <name> <project-url>   # claims the sandbox + spawns the stack
```

`ws-createlovbox` itself has three modes for the second arg:

```
ws-createlovbox <name>                      # scratch sandbox, no project (mode 1)
ws-createlovbox <name> <project-url>        # existing Lovable project (mode 2)
ws-createlovbox <name> <claim-name>         # existing sandbox by claim (mode 3)
```

The previous `--prompt` mode is removed — it talked directly to
`api.lovable.dev`'s project-create, which is now blocked by Castle for
any non-browser caller. Trying it prints an error pointing at ws-newlol.

`<name>` is the workspace short name — NO `daphen-` prefix. That prefix
belongs to local branches/worktrees only; ws-createlovbox prepends
`lovable-` itself. For Linear ticket EVERY-1186 about "Support private
npm registries", the name is `1186-private-npm-registries`, the
workspace becomes `lovable-1186-private-npm-registries`. Passing
`daphen-1186-...` as the second arg makes lovssh try to resolve it as
a claim/UUID and fail.

For an internal monorepo task (just need a sandbox to ship feature
work, no Lovable demo project), use mode 1 — scratch sandbox, skip
ws-newlol entirely.

Spawns a stack on a `lovable-<name>` workspace (same naming pattern as
ws-createwt so pickers show them together): lovssh→claude in
~/lovable, lovssh→nvim in ~/lovable, plus a work-profile browser if a
project URL is associated. No local worktree, no local devenv — the
sandbox owns both; edits happen remotely via SSH.

For reviewing a GitHub PR locally (different again — fetches the PR,
checks out on a `review/pr-<num>` branch, spawns the standard
4-window devenv stack), use `ws-createreview <pr-url-or-number>`.

Pick which script based on cues:

- Want a NEW LoL project, no URL yet → ws-newlol (browser only)
- LoL / "lovbox" / sandbox / project URL or claim given →
  `cockpit-add-lovbox <name> [url-or-claim]` — the sandbox becomes a
  REMOTE cockpit context (tabs land in it via lovssh; type claude/nvim
  after landing). ws-createlovbox's workspace-spawning half is retired;
  its provisioning survives via --provision-only underneath.
- New worktree / Linear ticket / local feature work → cockpit-add
- Reviewing someone else's PR → ws-createreview
- Lovable-on-Lovable work (LoL week: ship monorepo tickets via the agent) →
  `cockpit-add-lol <name>` — one LoL project + monorepo-clone sandbox as a
  cockpit context: agent tab drives the production agent (`lovc chat`),
  nvim/devenv SSH into the SAME sandbox for hands-on editing. Both modes,
  one sandbox. Headless spec→PR without a context: `lovc exec --lol`
  (see vault `references/lovc-cli.md`).

Confirm before invoking either: ws-createlovbox claims a paid sandbox,
ws-createreview fetches+branches off main. ws-newlol just opens a
browser — no confirmation needed.

**Never preemptively run `ws-close-stack` to "clean up" before creating
a new workspace.** It closes every window on the focused workspace; if
that workspace happens to be `lovable-main` (the user's persistent
primary), it wipes their browser, Slack, music etc. ws-close-stack
itself now refuses to operate on `lovable-main`, but other reserved
workspaces could exist. Only invoke when the user explicitly asks for
teardown of a specific worktree's stack.

# Cross-environment prompts

When composing a prompt that will be sent to a remote agent (LoL project
chat in the lovable.dev web UI, a separate Claude session, an agent
inside a lovbox SSH session, etc.), the receiving agent has no access to
my filesystem, env vars, or shell state. References to local paths like
`~/notes/foo.md` or `~/work/lovable/...` will dead-end on their side.

Inline the relevant content directly in the prompt instead of pointing to
local paths. Same goes for env vars, niri workspace state, browser context.
If a referenced file is too large to inline, mention that explicitly and ask
the user whether to scp it across or summarize.

# Commits

Never mention Claude, Claude Code, or Anthropic in commit messages. Do not add Co-Authored-By lines referencing Claude.

# Comments

Default to writing **no comments**. Only add one when the WHY is non-obvious:
a hidden constraint, a subtle invariant, a workaround for a specific bug, or
behavior that would surprise a reader. If removing the comment wouldn't
confuse a future reader, don't write it.

Specifically don't write:
- Comments that restate what well-named code does ("// Set the timeout to 30s")
- Section dividers ("// --- Helpers ---")
- Doc comments that just restate the function signature
- Narration openers ("// This function handles authentication.")
- References to the current task ("// Added for issue #123" — rots)
- Chain-of-thought ("// We chose Map because…")
- Multi-paragraph explanations — if needed, they belong in the PR or a doc

When you DO write one, one line. Two lines max.

# Subsystems map (proart)

For anything touching the desktop, look here before guessing:

- **NixOS config** — `~/nixos/` (flake). System + home-manager.
- **Dotfiles** — `~/nixos/dotfiles/` (stow-style layout, but home-manager does the
  symlinking, not stow; an in-repo subtree of nixos-config, not a standalone repo).
  See `~/nixos/dotfiles/SYSTEM.md` for the full architecture overview.
- **Quickshell (bar / pickers / notifications)** — `~/nixos/dotfiles/quickshell/.config/quickshell/`.
  Singletons in `modules/*State.qml`, pickers in `modules/*Picker.qml`, bar in `Bar.qml`.
- **Theme system** — `~/nixos/dotfiles/themes/.config/themes/`. `colors.json` → templates →
  `generated/<tool>/<mode>.theme` → `theme-manager.sh apply`.
- **Niri config + scripts** — `~/nixos/dotfiles/niri/.config/niri/`. Workspace stack scripts
  in `scripts/ws-*`. Window-jumping in `niri-jump-or-exec`.
- **palette-daemon** (cmd-palette overlay, source) — `~/personal/palette-daemon/`.
- **wpm-daemon** (bar WPM counter, source) — `~/personal/wpm-daemon/`.
- **Charybdis firmware fork** — `~/work/bastardkb-qmk/keyboards/bastardkb/charybdis/3x6/keymaps/daphen/`.
- **Agent rail (the cockpit agent)** — the in-nvim sidebar (roster/chat/composer)
  that drives `pi` sessions via the `agentd` daemon. This is the orchestrator you
  are (or are replacing): the rail UI is `~/nixos/pkgs/neovim/lua/agent-nvim/init.lua`,
  the daemon is `~/personal/agentd/` (Go, one socket per scope), and pi is the
  agent. **Read `~/personal/notes/storage/references/agent-rail.md` before touching
  any of it** — it has the full architecture, keybinds, dev loop, and the current
  state + pending work (e.g. true rewind for pi). Deploy note: nvim Lua / niri
  scripts / quickshell are live symlinks (nvim needs a restart to reload Lua;
  quickshell hot-reloads); agentd is Go (build + restart the daemon, which is
  disruptive to a live session).
  - **Coordinating with other agents** (agentd is the hub) — use the native
    `agent_*` tools: `agent_roster` lists active sessions; `agent_send <ref>
    <message>` dispatches a prompt to an existing agent (lands at its next idle);
    `agent_steer <ref> <message>` REDIRECTS a running agent IN REAL TIME — the
    message is injected into its live turn at the next tool boundary (before its
    next LLM call), not queued to turn-end (idle target → falls back to a normal
    prompt); `agent_read <ref> [N]` reads another agent's last N turns;
    `agent_spawn <dir> [prompt]` stands up a NEW roster agent in an existing dir
    (the orchestrator's way to launch per-ticket agents); `agent_review <pr>`
    reviews a PR the Pi-native way — it fetches the PR onto its OWN review/pr-<n>
    worktree and starts a rail session seeded with `/review-pr` (use THIS for PR
    reviews, never `agent_spawn` into the current checkout — that has no worktree
    or PR checkout, so the review has nothing to look at); `agent_whoami` is your
    own session name. `<ref>` is a session name, id, or cwd. (The desktop — niri
    pickers incl. the Super+r review picker, nvim keybinds, cockpit scripts — uses
    the sibling `agent` CLI: `agent roster|read|send|steer|spawn|review`, same
    protocol.) Steering is
    orchestrator → worker only — never wire up agent↔agent ping-pong. Spawning is NOT worktree-related — a full ticket kickoff with a
    worktree + devenv + rail tabs is `cockpit-spawn <name> [prompt]`. Shared
    knowledge = the notes vault. Root/orchestrator role + topology
    (orchestrator-mediated, no agent→agent ping-pong): see the rail reference +
    `inbox/orchestrator-bootstrap.md`.

# Memory routing

I maintain a personal notes vault at `~/personal/notes/storage/`. The
canonical model is **local-file-first**: notes live as markdown files in
the vault; a push-only watcher (`notes-cli -watch`, a systemd user
service) auto-syncs file changes UP to the backend (Neon via `/api/sync`),
where the `notes-memory` MCP indexes them for semantic search. Backend →
local is the rare direction, pulled on demand.

## Saving — write a FILE when the vault exists; MCP only as fallback

The MCP `save_memory`/`save_note`/`add_todo` tools write straight to the
backend and SKIP the local file — that makes phantom notes: searchable but
never in the vault, and they don't come down on their own. So:

- **When `~/personal/notes/storage/` exists locally** (proart, any machine
  with the vault): save by writing a markdown file into the right subdir —
  `inbox/` (quick notes), `journal/<YYYY-MM-DD>.md` (daily + todos),
  `plans/`, `references/`, `meetings/`, `memory/` (memories, with
  `name`/`description`/`metadata.type` frontmatter). The watcher syncs it
  up. Do NOT call the MCP `save_*` tools here.
- **When the vault dir is absent** (lovbox SSH sandboxes, the Lovable
  agent, mobile): use the MCP `save_*` tools — the backend is the only
  reachable store there.

## Recalling — pull-then-search

When the user asks to recall/find a memory or note and the vault exists
locally, **run `notes-cli -pull` first**, then search/read the vault
(`rg`/Read over `~/personal/notes/storage/`). The pull syncs down anything
written elsewhere (a lovbox, mobile) so recall sees the full picture; it's
authenticated, idempotent (path-keyed upserts, server mtime preserved),
and cheap, so a no-op pull when nothing changed is harmless. Where the
vault is absent, recall via `notes-memory.search_notes(query)` instead.

When the user mentions ongoing projects (design system work, the notes
webapp, dotfiles), proactively pull-then-search for relevant context
before answering — the auto-loaded memory holds only a few profile facts;
the bulk lives in the vault.

The filesystem auto-memory at `~/.claude/projects/-home-daphen/memory/` is
deprecated — the vault is canonical.

# Agentic execution — do the work, don't narrate intent

When you say you'll do something, DO IT in the same turn — make the tool calls
before you stop. Never end a turn with "I'll fix X / next I'll run Y / then I'll
update the plan" and then yield. That announces intent without acting: the
session goes idle, and the user has to manually poke "go ahead" for work they
already asked for. Announcing is not doing.

End a turn ONLY when one of these is true:
- the work you described is actually done, or
- you're blocked on a decision that is genuinely the user's to make (then ask
  the specific question — don't stall silently), or
- a command/tool failed and you need direction.

If you commit to a multi-step sequence (fix → rerun tests → update the plan),
carry it all the way through in the turn; don't stop after step one or after
merely planning the steps. A confirmed-needed fix (e.g. a release-blocking test
failure) is work to do now, not a status to report and yield on. Prefer
finishing over checking in — you already have permission for what was asked.

## Never a bare status — always end with the next action

Whenever you DO surface something short of done — a status update, a blocker, a
failed command, a "here's where we are" — it MUST end with the concrete NEXT STEP
in plain, unambiguous wording. Never leave David holding a status with no clear
action point. Until the task is actually finished, every message answers "so what
do I / you do now?"

- Not "CI is still running." → "CI is still running (~8 min left); I'll report the
  result when it lands — nothing for you to do yet."
- Not "The build failed." → "The build failed on X; I'm fixing X now" (then do it),
  or if it's genuinely your call: "The build failed on X — do you want A or B?"
- Not "Done, 3 files changed." → state what changed + the single next action, if any
  ("…restart heidr to load it", "…ready to push when you say go").

The next step is a real, specific action (a command, a decision to make, a thing to
restart/run/review) — not a vague "let me know" or "we could look into it." If the
task is truly complete, say so plainly and say there's nothing left to do. One
clear action point per message; no menu of possibilities.

# Output style — always apply (ADHD)

Shape EVERY response for an ADHD reader, on every turn, without being asked —
coding, debugging, explanations, casual chat alike. This is not optional and
does not require invoking a skill: apply it by default.

HARD RULES (checkable, not vibes):
- **Default budget: ≤6 lines.** A routine answer, status, or confirmation fits
  in six lines or fewer. Exceeding the budget requires one of: David asked for
  detail, the content is a deliverable (plan, review, post-mortem), or a
  decision needs the context to be decidable.
- **Line 1 = the answer or the next action.** Never preamble, never a recap of
  the question.
- **Long content = 1-line TL;DR first**, then compressed numbered sections.
- **No done-recaps.** After completing work: one line — what changed + where.
  No "here's everything we did" paragraphs unless asked.
- **Max one offer/follow-up line** at the end, only if genuinely
  decision-relevant. No menus of things you could also do.
- Number multi-step work; one action per line.
- Externalize state across turns — restate what's done / pending; nothing
  off-screen survives.
- Recommendation, not a survey. Tangents die in the thinking, not the reply.
- Concrete numbers over vague ("~20s", not "briefly").

Violating the budget with justified content is fine; violating it with
narration is a defect. When in doubt, cut.

The `i-have-adhd` skill holds the full rationale; this directive makes its
shaping the standing default rather than an on-demand invocation.
