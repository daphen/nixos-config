---
name: cycle
description: Generate the state-of-the-cycle record — pull the current Linear cycle's issues and cross-reference the vault's plan artifacts, writing a dashboard of every ticket's Linear status + plan state to the vault. Regenerated on demand. Triggers on "/cycle", "cycle status", "what's in this cycle", "weekly cycle review", "state of the cycle".
metadata:
  type: workflow
---

# cycle

Builds a durable, after-the-fact record of a Linear cycle by joining two sources:
**Linear** (the tickets + their workflow status) and the **vault's plan artifacts**
(whether a plan exists and what state it's in). Regenerated on demand — re-run any
time to refresh.

Local-only: it reads the vault at `~/personal/notes/storage/`. If that's absent
(a sandbox), say so and stop — `/cycle` is a local review tool.

## Steps

1. **Resolve the cycle.** Default to the **current/active** cycle of the `Everywhere`
   team (Linear MCP `list_cycles`). If the user passed a number (`/cycle 26`), use
   that one. Capture its number and start/end dates.
2. **Pull its issues** assigned to the user (`list_issues` filtered by cycle + the
   current user; `get_user`/"me" if you need the id). For each: identifier
   (`EVERY-####`), title, and Linear workflow status.
3. **Join the plan state.** For each issue, look for `~/personal/notes/storage/plans/<ID>.md`:
   - absent → `no plan`
   - present → read its `> Status:` line → `draft` | `planned` | `reconciled`
4. **Write the record** to `~/personal/notes/storage/cycles/cycle-<number>.md`
   (`mkdir -p` the dir). The watcher syncs it up; notes-memory indexes it. Overwrite
   on regenerate — it's a live snapshot, not an append log.

## Output format

```markdown
# Cycle <number> — <start> → <end>

> Generated <date -u +%Y-%m-%dT%H:%MZ> · team Everywhere · <N> tickets

| Ticket | Title | Linear | Plan |
|--------|-------|--------|------|
| [EVERY-1781](https://linear.app/lovable/issue/EVERY-1781) | Restart dev-server… | Todo | planned |
| [EVERY-2094](…) | … | In Progress | no plan |

**Plan coverage:** 4/7 tickets have a plan · 2 reconciled · 1 planned · 1 draft
```

Keep it scannable — link the ticket id, keep the title to one line. The plan-state
column is the value-add: at a glance you see which cycle work is planned, in flight,
or shipped (reconciled), and which tickets have no plan yet.
