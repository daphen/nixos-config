package main

import (
	"fmt"
	"regexp"
	"strings"
)

var (
	reviewPRPattern  = regexp.MustCompile(`^[1-9][0-9]*$`)
	reviewSHAPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

func runReviewWorktree(a app, pr, sha string) error {
	if !reviewPRPattern.MatchString(pr) || !reviewSHAPattern.MatchString(sha) {
		return fmt.Errorf("usage: vmctl worktree --review PR-NUMBER HEAD-SHA")
	}
	repo := a.vmRepo()
	target := repo + ".review-" + pr
	text, err := worktreeSSHResult(a, reviewWorktreeScript(repo, target, pr, sha))
	if err != nil {
		return fmt.Errorf("review worktree setup failed: %s", strings.TrimSpace(text))
	}
	fmt.Fprintln(a.out, target)
	return nil
}

func reviewWorktreeScript(repo, target, pr, sha string) string {
	return "set -eu\nrepo=" + shellLiteral(repo) + "\nwt=" + shellLiteral(target) + "\nbranch=review/pr-" + pr + "\nsha=" + sha + `
git -C "$repo" fetch --quiet origin "pull/` + pr + `/head"
[ "$(git -C "$repo" rev-parse FETCH_HEAD)" = "$sha" ] || { echo "PR head on GitHub is not $sha" >&2; exit 30; }
if [ -e "$wt" ]; then
  [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" = "$wt" ] && [ "$(git -C "$wt" branch --show-current)" = "$branch" ] || { echo "$wt exists but is not the $branch worktree" >&2; exit 31; }
  [ -z "$(git -C "$wt" status --porcelain=v1)" ] || { echo "review worktree $wt is dirty" >&2; exit 32; }
  head=$(git -C "$wt" rev-parse HEAD)
  [ "$head" = "$sha" ] || git -C "$repo" merge-base --is-ancestor "$head" "$sha" || { echo "review branch $head is not behind PR head $sha" >&2; exit 33; }
  git -C "$wt" reset --quiet --hard "$sha"
else
  old=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" || true)
  [ -z "$old" ] || git -C "$repo" merge-base --is-ancestor "$old" "$sha" || { echo "review branch $old is not behind PR head $sha" >&2; exit 33; }
  git -C "$repo" worktree add --quiet -B "$branch" "$wt" "$sha"
fi
[ "$(git -C "$wt" rev-parse HEAD)" = "$sha" ] || { echo "review worktree does not match PR head" >&2; exit 34; }
`
}
