#!/usr/bin/env bash
# standup gather: collect the day's REAL activity so the standup isn't
# reconstructed from memory or a Done-filter (which misses in-flight work).
# Usage: gather.sh ["<git-since expr>"]   default: "yesterday 00:00"
#   Monday covering Fri+weekend: gather.sh "last friday 00:00"
set -uo pipefail

SINCE="${1:-yesterday 00:00}"
SINCE_DATE="$(date -d "$SINCE" +%F 2>/dev/null || date +%F)"

echo "### window: commits/PRs since \"$SINCE\" ($SINCE_DATE)"
echo

echo "### git activity by branch — committed AND uncommitted"
echo "### (uncommitted line count catches hands-on in-flight work with no commit yet, e.g. a redesign built all day but not pushed. trivial (<10 lines) and abnormal (reset/broken) worktrees are filtered)"
found=0
for d in "$HOME"/work/lovable.daphen-*; do
  [ -e "$d/.git" ] || continue
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
  commits=$(git -C "$d" log origin/main..HEAD --since="$SINCE" --pretty='  %h  %an  %s' 2>/dev/null)
  ncommit=$(printf '%s' "$commits" | grep -c .)
  changed=$( { git -C "$d" diff --numstat 2>/dev/null; git -C "$d" diff --cached --numstat 2>/dev/null; } \
             | awk '{ if($1 ~ /^[0-9]+$/) a+=$1; if($2 ~ /^[0-9]+$/) a+=$2 } END{ print a+0 }')
  files=$( { git -C "$d" diff --name-only 2>/dev/null; git -C "$d" diff --cached --name-only 2>/dev/null; } | sort -u | grep -c .)
  # keep only real work: commits in window, OR non-trivial uncommitted (>=10 lines)
  { [ "$ncommit" -gt 0 ] || [ "$changed" -ge 10 ]; } || continue
  found=1
  if [ "$changed" -gt 50000 ]; then
    echo "- ${br}   [${ncommit} commits | ABNORMAL: ${files} files / ${changed} lines uncommitted — likely a reset/broken worktree, ignore]"
    continue
  fi
  echo "- ${br}   [${ncommit} commits in window | ${files} files, ${changed} lines uncommitted]"
  [ "$ncommit" -gt 0 ] && printf '%s\n' "$commits" | head -12
done
[ "$found" = 0 ] && echo "  (no worktree activity in window)"
echo

echo "### active agent sessions (in-flight; each = a ticket being worked)"
agent roster 2>/dev/null | sed 's/^/  /' || echo "  (agent CLI unavailable)"
echo

echo "### GitHub PRs you touched (opened / merged / reviewed) updated since ${SINCE_DATE}"
gh search prs --repo lovablelabs/lovable --involves=@me --updated=">=${SINCE_DATE}" \
  --limit 40 --json number,title,state,url 2>/dev/null \
  | python3 -c 'import sys,json
try:
    rows=json.load(sys.stdin) or []
    [print(f"  #{p[\"number\"]} [{p[\"state\"]}] {p[\"title\"]}") for p in rows]
    if not rows: print("  (none)")
except Exception as e: print(f"  (gh parse failed: {e})")' 2>/dev/null \
  || echo "  (gh search unavailable)"
echo

echo "### Linear — issues assigned to you, updated since ${SINCE_DATE} (all states, NOT just Done)"
if [ -n "${LINEAR_API_KEY:-}" ]; then
  resp=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: ${LINEAR_API_KEY}" -H "Content-Type: application/json" \
    --data '{"query":"{ viewer { assignedIssues(first: 50, filter: {updatedAt: {gte: \"'"${SINCE_DATE}"'\"}}) { nodes { identifier title state { name } updatedAt } } } }"}' 2>/dev/null)
  printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    if d.get("errors"): print("  (Linear API error:", d["errors"][0].get("message","?"), ")")
    else:
        ns=d.get("data",{}).get("viewer",{}).get("assignedIssues",{}).get("nodes",[])
        ns.sort(key=lambda n: n.get("updatedAt",""), reverse=True)
        for n in ns: print("  "+n["identifier"]+" ["+n["state"]["name"]+"] "+n["title"])
        if not ns: print("  (none assigned updated in window)")
except Exception as e: print("  (Linear query unavailable:", e, ")")'
else
  echo "  (LINEAR_API_KEY not set — skipping Linear)"
fi
echo

echo "### NEXT (for the summarizer — pi or claude, no MCP needed): dedupe by ticket across all signals above,"
echo "### weight by effort (commit count + uncommitted line count + 'most of the day' hands-on), then curate per"
echo "### the async-standup format. Biggest-effort item leads y:."
