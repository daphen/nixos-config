---
name: review-pr
description: Review a GitHub PR thoroughly and locally. Auto-detects the PR from a `review/pr-<num>` worktree branch (the shape agent-review leaves) or takes a PR number/URL, reads the diff plus the linked Linear ticket, fans out across correctness / security / tests / scope-vs-intent / perf, adversarially verifies every finding before reporting, and writes the ranked review to a markdown file (`~/personal/notes/storage/reviews/pr-<num>.md`) opened in neovim — the plan-ticket-style durable deliverable — plus a short verdict/summary in chat. NEVER posts to GitHub — the review is yours to act on. Triggers on "/review-pr", "review PR", "review this PR", "review pr-1234", "audit this PR".
---

# review-pr

Read-only, adversarial PR review. The product is a **ranked list of findings that
survived verification** plus a plain-English verdict — delivered locally, never
posted. Signal over volume: a short review of real problems beats a long one padded
with nits and false positives.

**Never posts to GitHub. Stays on the machine.** Do not run `gh pr review`,
`gh pr comment`, or any write — the review is yours to act on. The deliverable is a
review markdown file at `~/personal/notes/storage/reviews/pr-<num>.md`, opened in
neovim (the plan-ticket parallel — durable, synced, searchable), with a short verdict
+ summary in chat. Never post it to the PR.

## 1 — Resolve the PR

In priority order:
1. Explicit arg — a PR number or `https://github.com/<owner>/<repo>/pull/<n>` URL.
2. Current branch matches `review/pr-<num>` (what `agent-review` creates) → that's the PR.
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
general-purpose), one dimension or one area each. **These fan-out agents are
READ-ONLY analysis: no edits, no fixes, and NO commands — no builds, no `go test`,
no `direnv exec`, nothing that compiles or runs the suite.** Running verification
belongs to the single pass in step 4, done ONCE by the coordinating agent. If each
dimension agent runs the suite, you get N concurrent full monorepo builds
(`go test -parallel=24` ×N) that peg every core for 10+ minutes — the exact failure
this rule exists to prevent.

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
- Where cheap, **run it** — but this is the ONE place commands run, executed by the
  coordinating agent, **serially, once**. Never spawn the suite from a fan-out agent,
  and never run two suites at the same time (see step 3). **Scope it to what the diff
  touched** — the specific packages/tests for the changed files (`direnv exec . go test
  ./go/api/pkg/<changed-pkg>/...`), NOT the whole `./pkg/...` tree, and don't crank
  `-parallel`/`-p` past the default. A full-tree, high-parallelism run — or several at
  once — is what melts the CPU. Never claim a check passed without running it; report
  the CI rollup for everything you didn't run yourself.

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

In chat, keep it to the verdict + finding count + the document path — the markdown
file (step 6) is the real deliverable. If zero findings survived verification, say so
directly — a clean PR is a valid result, don't manufacture nits. Nothing is posted to
GitHub; offer to post only if they ask.

## 6 — Write the review document (markdown, opened in nvim)

The deliverable — the plan-ticket parallel. Write the full ranked review to
`~/personal/notes/storage/reviews/pr-<num>.md` (`mkdir -p` the dir first). No HTML,
no browser page. Structure it as plain markdown, same content as step 5:

- `# PR #<num> — <title>` + one metadata line (author · base←head · churn · ticket · CI).
- `## Verdict` — approve / request-changes / comment, one line why.
- `## Findings` — ranked blocker → should-fix → nit; each `### <severity> · file:line`
  with the concrete failure scenario, a one-line fix, and a fenced code block of the
  offending hunk where it clarifies. Refuted candidates go under `## Refuted` with why.
- `## Intent` — satisfied / missing / out-of-scope against the linked ticket.
- `## Verification` — what you actually ran + results; CI rollup for the rest.

Then open it via the rail's `:CockpitEdit` command (best-effort; silently no-ops
outside the cockpit). Use `:CockpitEdit`, NOT a bare `:e` — `:CockpitEdit` opens in a real
editor window and never a rail buffer (it skips every `agent-*` window and makes a
fresh vsplit if only the rail is up), so the review can't land in the composer/chat
even when a rail pane is focused:

```
sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kitty-cockpit-nvim"
[ -S "$sock" ] && kitty @ --to "unix:$sock" send-text $'\x1c\x0e'":CockpitEdit ~/personal/notes/storage/reviews/pr-<num>.md"$'\r'
```

(`\x1c\x0e` = `<C-\><C-n>` to force normal mode first; then the `:CockpitEdit` command
picks the editor window itself.)

To restyle every review, change this section — the file is plain markdown rendered by
the editor's markdown setup, never a hand-tuned page. Never post it to the PR.
