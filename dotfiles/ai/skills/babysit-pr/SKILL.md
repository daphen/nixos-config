---
name: babysit-pr
description: Spawn a dedicated subagent that watches a GitHub PR and reports NEW activity (CI results, review/bot comments, merge status) back to you every ~5 minutes until the PR is resolved.
argument-hint: "<PR number or URL>"
---

You've been asked to babysit a PR. **Spawn a dedicated long-lived subagent to watch it and report new findings back to you** — do NOT do the watching in this session (a multi-hour poll loop would tie it up). You are the spawner; the watcher becomes your child in the spawn lineage, so it's allowed to `agent_send` findings back to you.

## Steps (do these now)

1. **Resolve the PR number** from the argument: a bare number, or extract `#<n>` / the trailing number from a GitHub PR URL. If no argument was given, infer from the current branch: `gh pr view --json number -q .number`.
2. **Pick the watcher's dir**: the PR's local worktree if one exists (`~/work/lovable.daphen-*` / `~/work/lovable.review-*` matching the ticket), else the repo root `~/work/lovable`. The watcher only needs `gh` + the repo remote — no checkout required.
3. **Get your own session name** with `agent_whoami` — the watcher needs it to report back to you.
4. **`agent_spawn`** a subagent:
   - `dir`: the dir from step 2
   - `name`: `babysit-pr-<num>`
   - `oneshot`: **false** (it's long-lived)
   - `prompt`: the WATCH PROMPT below, with `<num>` and `<your-session-name>` substituted in.
5. Tell the user it's watching PR #`<num>`, that only NEW activity will be reported (quiet when nothing changes), and that it stops on its own when the PR resolves. Then you're done — the watcher runs independently.

## WATCH PROMPT (seed the subagent with exactly this, substituted)

You are babysitting GitHub PR #`<num>`. You are a PAGER, not a reviewer: you only OBSERVE and REPORT — never edit code, push, comment on the PR, or run any git operation that touches origin.

Report by calling `agent_send("<your-session-name>", "<finding>")` — send ONLY when there is genuinely new activity, and keep each report to a few tight lines.

Loop:
1. Gather current PR state with gh (no pager, e.g. `gh pr checks <num>` and `gh pr view <num> --json state,mergeStateStatus,reviewDecision,statusCheckRollup,reviews,comments`). Also pull the latest review threads / issue comments so you catch bot reviewers (Claude review, BugBot) and human reviewers.
2. Compare against what you saw on the previous poll (hold a baseline in your working memory).
3. If something is NEW — a check flipped to failing (or a previously-failing check went green), a fresh review or bot comment, or `reviewDecision`/`mergeStateStatus` changed — `agent_send` your spawner a compact summary: what changed + the actionable bit. Examples: `CI: bazel-e2e FAILED (was pending)`; `new Claude-review comment: <one-line gist> (link)`; `Khodor requested changes`; `mergeable now — all checks green, approved`. If nothing changed, send nothing.
4. `sleep 300` (bash, timeout 600), then repeat.

STOP the loop and let your turn end (go idle) when ANY of these is true — and send one final `agent_send` saying which:
- the PR is MERGED or CLOSED;
- it is APPROVED and every check is green (nothing left to babysit);
- your spawner tells you to stop;
- you have been polling for ~4 hours (a safety cap — report that you're stopping so nothing runs unbounded).
