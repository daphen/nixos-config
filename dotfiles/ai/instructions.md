# Universal routing and safety

Use `wt` (Worktrunk), never raw `git worktree`, for worktree operations.

Project context comes from `AGENTS.md` files loaded from the working directory.
For work started elsewhere, use these small routers when the paths exist:

- proart system or desktop work → read `/home/daphen/nixos/AGENTS.md`
- Cockpit work → read `/home/daphen/personal/ai-cockpit/AGENTS.md`
- agentd work → read `/home/daphen/personal/agentd/AGENTS.md`

Confirm before claiming a paid sandbox or fetching/branching a PR. Never remove,
close, or tear down a context unless the user names that exact context.

Remote receivers cannot read local paths, environment, or desktop state. Inline
the needed content, or ask before transferring material too large to include.

# Commits and comments

Never mention Claude, Claude Code, or Anthropic in commit messages, and never
add Co-Authored-By lines referencing Claude.

Default to no comments. Add at most two lines only for a non-obvious invariant,
hidden constraint, surprising behavior, or specific workaround. Do not narrate
what code does, add section dividers, restate signatures, reference the current
ticket, record reasoning, or put documentation-sized prose inline.

# Planning, review, and code quality

Simplest thing that works, always. These rules name failures that shipped:

- **Before planning or reviewing implementation, verify each requested outcome
  against current production code at a recorded SHA.** Trace the live path from
  sender through transport and required handshake to receiver; for writes,
  distinguish intentional locking or serialization from stale-read protection.
  Briefly record what already works, the exact missing step, and the smallest
  existing caller to change; trivial questions need no formal table. Treat
  tickets and historical diffs as clues, not current gaps or deletion quotas,
  and separate static evidence from an executed reproduction. Propose new
  architecture only after concrete evidence that the existing path cannot
  deliver the outcome; do not create an audit framework.
- **No exported symbol without a production caller.** Tests-only means inline or
  delete it, tests included.
- **No client-side mirror of server or DOM state.** No `*Ref` shadowing a field
  and no pending queue for values that “arrive out of order.”
- **No new protocol between components in one repo.** No hello/ack, version
  negotiation, or session matching to ask a component about itself.
- **Use `useEffect` only to synchronize with something outside React:** a
  subscription, socket, imperative API, timer, or DOM measurement. Compute from
  props/state during render; reset via `key`; handle user actions in handlers.
  If an effect sets state computable from existing values, delete it.
- **No code for a case you cannot produce today.** No unreachable defensive
  branch or option nobody passes.
- **Tests assert behavior through the public entry point,** never helper
  internals.
- **When logic moves across a boundary, the old implementation is the spec.**
  Preserve every input, branch, validation, and defense. Add a missing target
  field rather than generalizing away behavior; escaping is not sanitizing.
- **A hot-reloaded config is not live until the real loader accepts it.** Load
  QML, Lua, or unit changes in an isolated instance with the real runtime/import
  environment and inspect loader errors before reporting behavior.
- **Verification names the exact commit or dirty-patch hash it ran against.** A
  result recorded against earlier code is not evidence for the current change.
- **Nothing may need a development-only flag or override to work.** If it does,
  it is not done.

When a plan has a line budget, exceeding 1.5× is a stop: shrink the change
rather than raising the budget. Write approval cards and reports in plain
language: state the fact and ask, not internal gate names, tool jargon, or noun
stacks.

# Memory routing

The canonical memory is the local Markdown vault at `~/personal/notes/storage/`;
a push-only watcher indexes local changes remotely. Do not create that root on
machines where it is absent.

- If the real vault exists locally, save by writing the appropriate file under
  `inbox/`, `journal/`, `plans/`, `references/`, `meetings/`, or `memory/`. Do
  not use MCP `save_*` tools, which bypass the local source of truth.
- If the vault is absent (for example a lovbox), use the notes-memory MCP.
- Before recalling notes locally, run `notes-cli -pull`, then search/read the
  vault. Without a local vault, use notes-memory search.
- For ongoing projects, proactively pull then search before answering.

The old `~/.claude/projects/-home-daphen/memory/` store is deprecated.

# Execution and output

Do the work in the same turn you announce it. A turn ends only when the outcome
exists, a concrete user decision/human action blocks it, or a verified delegated
task is still running and will notify with its outcome. Fix and rerun ordinary
failures instead of stopping at status. Never end on a bare status: name exactly
one next action unless the task is complete, then say nothing remains.

Shape every response for an ADHD reader:

- Routine answers, statuses, and confirmations use at most six lines. Longer
  deliverables or decision context start with a one-line TL;DR.
- Line 1 is the answer or next action; no preamble.
- Number multi-step work with one action per line, and restate done/pending
  state across turns.
- After completion, give one concise result rather than a recap; add at most one
  decision-relevant follow-up.
- Prefer a recommendation and concrete numbers over surveys or vague timing.

The `i-have-adhd` skill contains the rationale; these rules apply without
invoking it.
