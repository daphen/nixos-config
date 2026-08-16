---
name: watch-pr
description: Spawn a read-only watcher child for one GitHub PR. Agentd wakes it about every three minutes while it remains idle between one-check turns; it reports only deltas to its lovable-worker parent.
argument-hint: "<PR number or URL>"
---

# Watch a PR

Run this only from a `lovable-worker`. The watcher is a pager, not a reviewer or implementer.

1. Resolve the PR number from the argument, or from `gh pr view --json number -q .number` when omitted.
2. Call `agent_whoami` and retain the exact parent session name.
3. Call `agent_spawn` with:
   - `dir`: the current worker worktree;
   - `name`: `watch-pr-<number>`;
   - `profile`: `lovable-watcher`;
   - `oneshot`: `false`;
   - `prompt`: the watcher prompt below with the PR number and parent name substituted.
4. Tell David that each check is a short turn, the watcher remains roster-idle for about three minutes between checks, reports only deltas, and stops on merge, close, approved-all-green, parent instruction, or four hours.
5. When any watcher report arrives, verify it against current HEAD and explicitly disposition it. Implement and test valid in-scope findings; reject stale, invalid, or out-of-scope findings with evidence; identify infrastructure failures separately. Never merely acknowledge a watcher report and abandon it.
6. For a typed review-finding context, commit only the validated remediation, then call `agent_disposition_review_findings` with every finding state, test evidence, and commit SHA. A successful implemented+tested disposition permits one same-branch non-force push; all initial, unrelated, PR-edit/comment, and merge actions still require David's exact current-turn request.

## Watcher prompt

You are the read-only watcher for GitHub PR #`<number>`, attached only to worker `<parent>`.

This initial turn must:
1. Establish a baseline with `gh pr checks <number>` and `gh pr view <number> --json state,mergeStateStatus,reviewDecision,statusCheckRollup,reviews,comments,url,headRefName,headRefOid`. Use read-only `gh api` GET requests when needed for review threads and issue comments.
2. Do not report the baseline itself.
3. If the PR is already terminal, send one final reason to `<parent>` and call `agent_stop_self`.
4. Otherwise call `agent_schedule_self` exactly once and end the turn immediately.

On every agentd-scheduled turn:
1. Gather the same state once—no retry loop.
2. Compare it with the baseline retained in this conversation.
3. For each new actionable review finding, call `agent_report_review_findings` once with PR number, the baseline's exact `headRefName`/`headRefOid`, and findings containing stable IDs, URLs, and complete allowed remediation paths. Do not also send those findings as prose.
4. For non-finding CI/comment/approval/merge-state changes, call `agent_send` targeting `<parent>` with a compact delta, exact evidence, and links. Send nothing when unchanged.
5. Replace the in-conversation baseline.
6. On merge, close, approved with every check green, or parent stop instruction: send one final reason and call `agent_stop_self`.
7. Otherwise call `agent_schedule_self` exactly once and end the turn immediately.

Agentd persists a single replaceable self-timer, wakes only this watcher after about three minutes, cancels it on stop, and enforces the four-hour deadline. Never use `sleep`, `--watch`, shell loops, foreground polling, shell background jobs, detached processes, or any other way to stay streaming between checks.

Never edit/write files, review or implement findings, run tests, mutate git/origin, push/post/merge, use MCP/browser/approval tools, spawn children, ask David questions, or message any session except `<parent>`.
