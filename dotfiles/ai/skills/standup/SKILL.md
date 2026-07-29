---
name: standup
description: Generate David's async standup (y:/t:) from REAL activity, not memory. Gathers git commits + uncommitted work across all worktrees, active worktrees, GitHub PRs, and Linear issues in ALL states, then curates per the standup format. Triggers on "standup", "async standup", "standup for today", "/standup".
---

# Standup

Generate the async standup from **actual activity**, never reconstructed from memory or a Done-filter. The recurring failure this fixes: work with no merge and no Linear "Done" — especially a ticket you built by hand all day but never committed/pushed (e.g. a UX redesign) — is invisible unless you look at git + worktrees directly.

## Step 1 — gather (run the script)

```
bash ~/.claude/skills/standup/gather.sh "<since>"
```
- Default `<since>` = `"yesterday 00:00"`. Monday covering Fri+weekend: pass `"last friday 00:00"`.
- It prints, for the window: per-branch **committed** work (across every `~/work/lovable.daphen-*` worktree, ahead of origin/main) AND **uncommitted line counts** (the hands-on-but-uncommitted signal), the **active worktrees** (`wt-send --list`), and **GitHub PRs** you touched.

## Step 2 — gather Linear (ALL states)

Query Linear via MCP — do NOT filter to Done:
`list_issues(assignee: "me", project: "Design Systems", updatedAt: "-P2D", limit: 40)` (widen the window for Fri+weekend). Note each issue's **state** (Done / In Review / In Progress / Todo) and `completedAt`/`startedAt`. In-progress and in-review count as "worked on."

## Step 3 — dedupe + weight by effort

Map every signal to a ticket (`EVERY-NNNN`, from branch names + Linear) and dedupe. Weight by real effort:
- Commits in window, and **uncommitted line count**, are effort signals — a branch with 1000 uncommitted lines was a major focus even with 0 commits and no "Done."
- **Caveat:** uncommitted diffs have no timestamp. Before counting an *uncommitted-only* item as today's work, confirm it's genuinely in-flight: it should appear in the **active-worktrees** list, or be In Progress/In Review in Linear. If a big uncommitted diff sits on a branch whose ticket is already Done/merged, it's stale leftover — don't count it. If unsure, ask.
- The **biggest-effort item leads `y:`**, even if it's not merged.

## Step 4 — dedupe against what was actually posted

Two sources, Slack is authoritative:

1. **Slack (primary).** Use the Slack MCP on `#team-everywhere` — channel id **`C099112QXR7`** (NOT `#team-everywhere-alerts` C0AGBV9P94P, which is incident noise, and NOT the `-internal`/`-vents` channels). Standups are posted as **thread replies under a daily "Standup Bot" async-standup prompt**, not as top-level messages. So: `slack_read_channel` to find the previous working day's Standup Bot prompt, then `slack_read_thread` on it to read David's actual reply. That reply is what was *sent* — the local log only captures what got logged. (`slack_search_public_and_private` for David's `y:`/`t:` text is a faster shortcut when it hits, but it misses thread replies sometimes; fall back to reading the thread.)
2. **Local log (fallback / cross-check):** `~/personal/notes/storage/references/standups-sent.md`, last 3 entries. Use it if Slack is unreachable or the channel read comes up empty.

**Reconcile the log against Slack on every run.** David edits the standup in
the composer before sending and does not always mention it, so the previous
day's Slack reply is often NOT what `standups-sent.md` recorded. After reading
the thread in 4.1, diff it against that day's entry in the local log; when they
differ, **overwrite the log entry with the Slack text** — Slack is what
teammates actually read, so it's the truth the dedupe must run against. Tell
David in one line that the log drifted; don't narrate the diff.

Dedupe rule: a shipped item may be reported as shipped ONCE — if a bullet re-reports something already posted as done, drop it. Multi-day work must read as progression, not repetition: "started X" → "shipped X" is fine; two days of "continued working on X" verbatim is not (vary by what actually moved). If both sources are unavailable, note that to David rather than silently skipping.

## Step 5 — curate into the standup

Follow the async-standup format ([[feedback_async_standup_format]]): `y:` / `t:`, terse `•` bullets, NO title line, lowercase, outsider-legible (non-DS teammates — no ticket IDs, no jargon), no em dashes ([[feedback_no_em_dashes]]). `y:` = the window's work, both **shipped and in-progress**; `t:` = today's actual top work (not "planning", not teammates' tickets). Relabel `y:` to `f/weekend:` etc. when the window spans more than yesterday.

**Never in the standup** (2026-07-29):

- **Review status or the act of reviewing.** No "pr is up", "in review", "get X through review", "reviewed Y". Report the WORK, and report it again only when it ships. Reviewing teammates' PRs is not standup content at all.
- **Meetings, unless the attendee is a customer.** Internal syncs, progress reviews, planning sessions: out. A customer call is worth a line.
- **On-call and goalie duty**, including pages handled, unless a page turned into real work worth reporting on its own.

**Terse means one line per bullet, hard cap.** After drafting, strip every
clause that doesn't change what the reader knows about the WORK itself:
process narration ("after a hardening pass from review", "after some back
and forth"), effort adjectives ("big chunk of", "proper"), and mechanism
detail nobody acts on (handshake/gating specifics — "frames render on cold
sandboxes" is the outcome, keep only that). If a bullet wraps past one line,
it's carrying one of these — cut it, don't rewrap it.

David-approved calibration reference ("that's the perfect verbosity",
2026-07-22) — match this density:

```
y:
• landed preview serving from the built output, frames now render on cold sandboxes
• built select-a-component-in-canvas-frames; testing blocked on local canvas rendering
• small follow-up PR up for faster local preview iteration

t:
• fix the environment, verify the selection feature end to end
• pick up the figma connector issue blocking uber
```

## Step 6 — offer clipboard, then log what was sent

Offer to copy via `wl-copy` as **asterisk-free plain text** (David's Slack composer renders pasted asterisks literally — see [[slack-format]] caveat).

After David confirms (or pastes his edited final version — prefer that over the draft), append it to `~/personal/notes/storage/references/standups-sent.md` under a `## YYYY-MM-DD` heading. The watcher syncs it up. If he sends a reworked version later, replace that day's entry. This log is what Step 4 dedupes against — without it the repetition check has nothing to compare to.
