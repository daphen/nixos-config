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
2. **◆ <new step>** — one bold lead sentence saying what this step does.
   - short bullets for the how and the why — one point each, never a prose wall
   - the live view shows this body verbatim as the step's (and diagram node's)
     expandable detail, so structure it for reading
   _(→ D1 · files: foo.go)_
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
Where files land and why. This list IS the boundary: `--go` will not touch anything
outside it without asking, and `--reconcile` checks we held the line. One item per
file — action + path on the first line, a short why beneath (it wraps; keep it tight).
List items in **flow order** (the order their step runs), so the review walks
top-to-bottom in execution order.

- **modify** `path/to/file.go`
  Why this file changes.
- **create** `path/to/new.go`
  Why this new file exists, kept minimal.

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

## Amendments
_(scope added after the initial plan, newest last; filled by `--amend` — the boundary
moved on purpose, recorded here so the "did it stay small?" review stays honest)_
- _none yet_

---
## Reconciliation
_(filled by `--reconcile`; full detail in review.json)_
- Planned N files, touched N. Extras: …
- Missing steps (planned, no change): none / …
- Drift: none / <explanation>
- Verification: X/Y passed · manual pending: …
