# {{TICKET}} — {{TITLE}}

> Status: `draft` · {{DATE}} · worktree: `{{BRANCH}}`
> The artifact is the source of truth. Edit any section; `--go` honors your edits.

## The shape
One to three lines, dumbest possible terms — what we're doing and why.
Readable in five seconds, no detail.

## The flow
The end-to-end flow with existing steps shown for context and NEW work marked **◆**.
This is where you see the new work sitting inside the pipeline — and confirm we're
adding the minimum. New steps may land at different points in the flow; say so.

1. <existing step, for context>
2. **◆ <new step>** — plain English. _(→ D1 · files: foo.go)_
3. <existing step>
4. **◆ <new step>** — happens later in the flow than step 2, because …
5. <existing step> → done

## Decision points  ← your calls
Real architectural forks only. If empty, the plan is hiding the architecture.

### D1. <the question>
- **A** — <description>. Trade-off: …
- **B** — <description>. Trade-off: …
- **Recommendation:** A, because …
- **Your call:** _(unresolved)_

## Surface area — the containment boundary
Where files land and why. This table IS the boundary: `--go` will not touch
anything outside it without asking, and `--reconcile` checks we held the line.

| File | Action | Why (one line) |
|------|--------|----------------|
| path/to/file.go | modify | … |
| path/to/new.go | create | … |

*New: N · Modified: N · Touched: N*

Placement (new files sit next to what already exists — sanity-check the shape):
```
internal/foo/
  handler.go        ~ modify   (add endpoint)
  service.go        + new      (logic, kept out of handler)
  service_test.go   + new      (covers the branch)
```

## Verification
How we'll know each piece works without reading the code:
- test … asserts …
- manual: … expect …

## Out of scope
Deliberately not touching — keeps the blast radius small and visible.

---
## Reconciliation
_(filled by `--reconcile`; full detail in review.json)_
- Planned N files, touched N. Extras: …
- Missing steps (planned, no change): none / …
- Drift: none / <explanation>
- Verification: X/Y passed · manual pending: …
