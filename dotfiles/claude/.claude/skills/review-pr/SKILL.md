---
name: review-pr
description: Review a GitHub PR thoroughly and locally. Auto-detects the PR from a `review/pr-<num>` worktree branch (the shape ws-createreview leaves) or takes a PR number/URL, reads the diff plus the linked Linear ticket, fans out across correctness / security / tests / scope-vs-intent / perf, adversarially verifies every finding before reporting, and hands back a ranked review in chat and, by default, opens a self-contained visual review page in the browser. NEVER posts to GitHub — the review is yours to act on. Triggers on "/review-pr", "review PR", "review this PR", "review pr-1234", "audit this PR".
---

# review-pr

Read-only, adversarial PR review. The product is a **ranked list of findings that
survived verification** plus a plain-English verdict — delivered locally, never
posted. Signal over volume: a short review of real problems beats a long one padded
with nits and false positives.

**Never posts to GitHub. Stays on the machine.** Do not run `gh pr review`,
`gh pr comment`, or any write — the review is yours to act on. The text review is
ephemeral: not written to disk, it lives in this conversation (offer to drop it into
an nvim buffer). The visual render in step 6 is a self-contained local HTML file
opened in your browser — no network, no cloud — and it's produced **by default** at
the end of the review. Never post either form to the PR.

## 1 — Resolve the PR

In priority order:
1. Explicit arg — a PR number or `https://github.com/<owner>/<repo>/pull/<n>` URL.
2. Current branch matches `review/pr-<num>` (what `ws-createreview` creates) → that's the PR.
3. Else `gh pr view --json number` on the current branch; if none, `gh pr list` and ask which.

Everything downstream uses `gh` (authenticated) — no GitHub MCP needed.

## 2 — Gather context (before reading a single line of diff)

- **PR metadata:** `gh pr view <num> --json title,body,author,baseRefName,headRefName,url,additions,deletions,files,state,isDraft,labels,statusCheckRollup,closingIssuesReferences`
- **The diff:** `gh pr diff <num>` (authoritative). On the review worktree you can also `git diff <base>...HEAD` — cross-check if they disagree.
- **Stated intent:** the PR body/title, AND the linked Linear ticket. Find it via `closingIssuesReferences`, the branch name, or an `EVERY-####` in the body; pull it with the Linear MCP (`get_issue`) for the real acceptance criteria. The intent is the yardstick for the scope pass.
- **CI:** read `statusCheckRollup` — note failing/pending checks; they inform (not replace) your own verification.

If the diff is large or spans unrelated areas, **delegate reading to subagents by area** — one per package/dimension — rather than skimming it all in one pass.

## 3 — Review dimensions (read-only, thorough)

Cover each; for a sizeable diff, fan these out to parallel subagents (Explore /
general-purpose), one dimension or one area each. No edits, no fixes.

- **Correctness** — logic errors, off-by-one, nil/err handling, concurrency, edge cases the change introduces or fails to handle.
- **Security** — authz/ownership boundaries, injection, unsafe input, leaked secrets, unsafe deserialization.
- **Tests** — does the change have tests that actually *assert* the new behavior (not just run it)? Missing cases, weakened assertions, tests that can't fail.
- **Scope vs intent** — does the diff do what the ticket/PR says? Flag both directions: unrelated/out-of-scope changes, AND stated requirements with no corresponding change.
- **Hard-to-reverse** — wire format, public ids, schema/migrations, API contracts, auth boundaries. These get extra scrutiny; a bug here outlives the PR.
- **Performance** — N+1 queries, needless allocations in hot paths, blocking calls on the request path. Only when plausibly real, not speculative.

## 4 — Verify every finding (adversarial — this is the point)

Before a finding reaches the report, **try to refute it.** For each candidate:
- Re-read the surrounding code and the rest of the diff — is there already a guard, a caller-side check, or a test that covers it?
- Is the bad path actually reachable with real inputs?
- Where cheap, **run it**: build, lint, or the specific tests touching the changed files (via `direnv exec . <cmd>` in the worktree). Never claim a check passed without running it; report CI rollup for what you didn't run.

Drop anything that doesn't survive. A finding you can't state a concrete failure scenario for is not a finding. When in doubt on a judgment call, keep it but label it clearly as unverified/opinion rather than asserting a bug.

For thorough runs, prefer *independent* verification — a second subagent whose only job is to refute the finding — over re-reading with the same eyes.

## 5 — Report (local, ranked)

Deliver in chat, most-severe first. Keep it tight.

- **Verdict** — your recommendation as advice, not a posted review: **approve / request-changes / comment**, one line of why.
- **Findings**, ranked, each with:
  - severity — **blocker** (must fix) / **should-fix** / **nit**
  - `file:line`
  - what's wrong + the concrete failure scenario (inputs → wrong result)
  - suggested fix, one line
- **Intent check** — does it satisfy the ticket; what's missing or out of scope.
- **Verification** — what you actually ran (build/tests/lint) and the result, plus CI status for the rest. Be honest about what you couldn't verify.

End by stating plainly that nothing was posted to GitHub, and offer to post it (or open it in nvim) only if they ask. If zero findings survived verification, say so directly — a clean PR is a valid result, don't manufacture nits.

## 6 — Visual render (default)

Finish **every** review by rendering it as a **self-contained local HTML page** and
opening it in the browser — this is the default deliverable, not an extra. The text
review from step 5 stays the source of truth; this is a view of it, not a re-review.
Skip it only if the user explicitly asked for text-only.

**Do not author the page from scratch.** The skeleton, all CSS, and the theme palette
live in `template.html` (this skill's dir); you produce only the content *fragments* and
hand them to the renderer, which inlines the current-mode palette (from
`~/.config/themes/generated/review/<mode>.theme`, driven by `~/.config/theme_mode`) and
writes the stable path `~/.cache/pr-reviews/pr-<num>.html`:

```
python3 <skill-dir>/render.py <num> <fragments.json>   # prints the output path
setsid pr-review-open <num> >/dev/null 2>&1 &          # serves it + opens a chromeless app window
```

`pr-review-open` serves the page on localhost (live-reload on re-render; `o` jumps the
review worktree's nvim to the finding's file:line via its `/open` endpoint) and opens it
as a helium `--app` window. Re-rendering after it's up just updates the open window.

`fragments.json` keys (each a raw HTML string built with the component classes the
template documents in its header comment — **colours are `--rv-*` vars + `color-mix`, never
hex**):

- `title` — the PR title.
- `meta` — one line: PR #, author, state, base←head, +add/−del, file count, github + ticket links.
- `verdict_class` / `verdict_badge` — class stays `approve|changes|comment`; the badge
  label speaks plainly: "approve", "needs changes", "comments". `verdict_why` — one
  plain-English line + a `<span class="note">` caveat, readable without the diff.
- `story` — **the change explained from scratch**, right under the verdict, for a
  reader who doesn't know the feature. Two to four short `<p>` paragraphs in this
  shape: the setup (what exists today and why), the problem (what's wrong or
  duplicated or missing), what the PR does about it — and, when it wasn't a
  mechanical change, one paragraph on why. No file names, no jargon, no diff
  knowledge assumed; write it like explaining the PR to a teammate who just walked
  in. If a finding only makes sense inside this story, say where it fits.
- `diagram` — **the centrepiece.** `.lane`/`.node`/`.arrow`/`.split` markup showing *how this change works*, chosen to fit the PR: data-flow pipeline, state machine, before/after, or sequence. Label real files/symbols. At least half the page's weight is this + the annotated code, not prose.
  Node `.sub` text is **plain English for someone who hasn't read the diff** — a full
  sentence saying what happens at this node and why it matters, never a compressed
  jargon chain ("D1 probe: passthrough verified"). Together the nodes must tell the
  change's whole story end to end. Long explanations anywhere on the page are a lead
  sentence + short bullets, never a prose wall.
- `findings` — one `.finding` per issue, ranked blocker → should-fix → nit, **each an annotated `<pre>` of the actual hunk** (offending line `.ln.bad`, good line `.ln.good`). Not text cards describing invisible code. Put `data-file="<repo-relative path>" data-line="<line>"` on each `.finding` (and any file-anchored `.frow`) so `o` can open it in nvim.
  The reasoning under the hunk is **three labeled plain-English rows** — write them for
  someone who hasn't read the diff, no compressed jargon chains:
  - `<p class="note"><b>Problem:</b> …</p>` — what's wrong, one plain sentence ("a `false` value silently disappears from the variant API response, but not from the project one").
  - `<p class="why"><b>Why it matters:</b> …</p>` — the concrete consequence if left ("a client can't tell 'not fragile' apart from 'field missing', which will bite when someone reads the raw payload").
  - `<p class="fix"><b>Fix:</b> …</p>` — the one-line change.
  Refuted candidates: `.ln.strike` on the suspected lines + a single `.note.drop` with `<b>Refuted:</b>` explaining in the same plain terms why it's not real.
- `filemap` — `.grp` columns (by area) with per-file `.bar` change-size bars. Not a table.
  Bar width is total churn (adds+deletes) on a fixed pixel scale: the biggest file gets
  `width:180px`, every other bar `round(churn/max*180)px` — never percentages, so bars
  stay comparable across rows and columns.
- `intent` — `<li>` items against the linked ticket (satisfied / missing / out-of-scope),
  each a full sentence someone who hasn't read the ticket can follow — name the behavior,
  not internal shorthand.
- `verification` — rows: what you actually ran + results, CI rollup for the rest.

Build fragments straight from the diff you already read. To restyle *all* reviews, edit
`template.html` once — never hand-tune a rendered page. The output is
ephemeral/regenerable and reopenable via `pr-review-open <num>`; never post it to the PR.
(To *share* with a teammate, a Claude Artifact is the alternative render — hosted on
claude.ai, so opt-in, not the local default.)
