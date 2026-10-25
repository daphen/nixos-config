package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeReviewWorktreeTracksPRHead(t *testing.T) {
	f := newRetirementFixture(t, "")
	repo := filepath.Join(f.home, "src/lovable")
	os.MkdirAll(filepath.Dir(repo), 0o755)
	runGit(t, f.home, "clone", f.remoteRepo, repo)
	publish := func(content string) string {
		os.WriteFile(filepath.Join(f.remoteWT, "README.md"), []byte(content), 0o644)
		runGit(t, f.remoteWT, "commit", "-qam", content)
		head := strings.TrimSpace(runGit(t, f.remoteWT, "rev-parse", "HEAD"))
		runGit(t, f.remoteRepo, "update-ref", "refs/pull/9/head", head)
		return head
	}
	review := func(sha string) result {
		return runWorktreeBinaryArgs(t, f.home, f.path, "--native", "--review", "9", sha)
	}
	want := repo + ".review-9"

	first := publish("one\n")
	got := review(first)
	if got.err != nil || got.stdout != want+"\n" {
		t.Fatalf("first review=%+v", got)
	}
	if b := strings.TrimSpace(runGit(t, want, "branch", "--show-current")); b != "review/pr-9" {
		t.Fatal(b)
	}
	if got := review(strings.Repeat("a", 40)); got.err == nil || !strings.Contains(got.stderr, "PR head on GitHub is not") {
		t.Fatalf("stale head accepted: %+v", got)
	}

	second := publish("two\n")
	if got := review(second); got.err != nil || got.stdout != want+"\n" {
		t.Fatalf("updated review=%+v", got)
	}
	if head := strings.TrimSpace(runGit(t, want, "rev-parse", "HEAD")); head != second {
		t.Fatal("review worktree did not move to the new PR head")
	}

	os.WriteFile(filepath.Join(want, "README.md"), []byte("local\n"), 0o644)
	third := publish("three\n")
	if got := review(third); got.err == nil || !strings.Contains(got.stderr, "dirty") {
		t.Fatalf("dirty review worktree reset: %+v", got)
	}
	runGit(t, want, "checkout", "README.md")

	runGit(t, f.remoteWT, "reset", "-q", "--hard", first)
	rewritten := publish("rewritten\n")
	if got := review(rewritten); got.err == nil || !strings.Contains(got.stderr, "is not behind PR head") {
		t.Fatalf("force-pushed PR replaced the review checkout: %+v", got)
	}
	if strings.Contains(readLog(t, f.log), "ssh|") {
		t.Fatal(readLog(t, f.log))
	}
}
