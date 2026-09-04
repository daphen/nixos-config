# {{TICKET}} — {{TITLE}}

> Status: `draft` · {{DATE}} · worktree: `{{BRANCH}}`
> The artifact is the source of truth. Edit any section; `--go` honors your edits.

## The shape
Two sentences, in this order: **what happens today that is wrong**, then **what it will
do instead**. Write it for someone who has never seen the ticket and does not know this
codebase's vocabulary — a colleague reading over your shoulder, not a reviewer who
already agrees with you.

Hard rules, because "dumbest possible terms" alone produced dense jargon:
- **Name the actors and the action.** "The agent asks the canvas worker to…" beats
  "actions are validated". Who does what to what.
- **No noun stacks.** Three or more nouns in a row is a rewrite: "typed atomic
  envelope", "pointer-only state", "source-guidance slot" tell the reader nothing.
- **No term-of-art nouns** unless the ticket is literally about naming them: envelope,
  contract, surface, primitive, seam, vocabulary, slot, boundary.
- **No counts of unnamed things.** "five preview-shape verbs" — name them or drop the
  number.
- **Nothing but the change.** Blockers, decisions, scope and sequencing have their own
  sections; a blocker in the shape hides the shape.
- **The test:** could the reader repeat it back in their own words after ONE read? If it
  needs a second pass, it is not the shape yet.

Worked example — this failed the test:
> Replace freeform canvas actions with one typed, atomic envelope for five preview-shape
> verbs. The server validates and persists pointer-only state.

and this is the same change, passing it:
> Today the agent can send the canvas worker almost any shape-change it likes, and the
> worker copies whatever it is given onto the record. Instead the agent will send one
> request containing only named operations — create, update, set status, move, delete a
> shape — which the server checks and then applies all together or not at all.

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
Flow forks only — how it should BEHAVE, never how the code is arranged. Only
questions the goal itself doesn't answer (derivability test). Empty is fine.

### D1. <the question>
- **A** — <description>. Trade-off: …
- **B** — <description>. Trade-off: …
- **Recommendation:** A, because …
- **Your call:** _(unresolved)_

## Decided — derivable calls, locked
One-liners: choice + the goal/pattern that implies it. Veto by editing the
line before `--finalize`; these never block approval.
- <choice>, because <what makes it the obvious answer>.

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

**Budget: ~N lines changed.** The size this SHOULD cost, decided before writing code.
`--reconcile` fails if the real diff exceeds 1.5× — and the required response is to
STOP and report what must shrink, never to raise the budget. EVERY-2739/2741/3064
spent +970 lines answering "how big is this component?", whose correct answer was
"store w/h when you snapshot it". A budget is what makes that visible on day one.

**Simplest alternative** — one line per ◆ step that introduces a MECHANISM (a
protocol, a cache, mirrored state, a version gate, a new module):
- ◆N: simplest alternative was <X>; rejected because <falsifiable reason>.
If the reason is not falsifiable ("more flexible", "future-proof", "cleaner"), the
mechanism does not go in the plan. A postMessage handshake with version negotiation
would never have survived this line.

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
- Budget: ~N planned vs N actual lines (over 1.5× ⇒ STOP and report what shrinks)

### Simplicity pass — answer with evidence, delete what you cannot answer
- New exported symbols → **name each one's production caller.** No caller means it is
  dead on arrival: inline it or delete it, with its tests. (`candidatePreviewRevisionMessage`
  shipped exported, 160 lines of tests, and zero production callers.)
- New files → **why couldn't this live in an existing file?** One sentence each.
- Any state mirroring the server or the DOM (`*Ref`, a pending queue, a cache) →
  **why can it not be read at the point of use?** (`revisionRef` + `pendingStatusRef`
  existed only to manage a race the design itself created.)
- Any test asserting a helper's internals rather than behaviour through the public
  entry point → rewrite or delete it.
- Anything that needs a dev-only flag or override to work → not done. Say so plainly.
