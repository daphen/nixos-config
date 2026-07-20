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

Dedupe rule: a shipped item may be reported as shipped ONCE — if a bullet re-reports something already posted as done, drop it. Multi-day work must read as progression, not repetition: "started X" → "shipped X" is fine; two days of "continued working on X" verbatim is not (vary by what actually moved). If both sources are unavailable, note that to David rather than silently skipping.

## Step 5 — curate into the standup

Follow the async-standup format ([[feedback_async_standup_format]]): `y:` / `t:`, terse `•` bullets, NO title line, lowercase, outsider-legible (non-DS teammates — no ticket IDs, no jargon), no em dashes ([[feedback_no_em_dashes]]). `y:` = the window's work, both **shipped and in-progress**; `t:` = today's actual top work (not "planning", not teammates' tickets). Relabel `y:` to `f/weekend:` etc. when the window spans more than yesterday.

## Step 6 — offer clipboard, then log what was sent

Offer to copy via `wl-copy` as **asterisk-free plain text** (David's Slack composer renders pasted asterisks literally — see [[slack-format]] caveat).

After David confirms (or pastes his edited final version — prefer that over the draft), append it to `~/personal/notes/storage/references/standups-sent.md` under a `## YYYY-MM-DD` heading. The watcher syncs it up. If he sends a reworked version later, replace that day's entry. This log is what Step 4 dedupes against — without it the repetition check has nothing to compare to.
