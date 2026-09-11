package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var binary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "vmctl-test-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	binary = filepath.Join(dir, "vmctl")
	if text, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		panic(string(text))
	}
	os.Exit(m.Run())
}

func TestRejectsTicketBeforeInterpolation(t *testing.T) {
	home, path, log := fixture(t, `echo called >> "$VMCTL_LOG"`)
	result := run(t, home, path, "sync", "EVERY-1;touch-pwned")
	if result.err == nil || !strings.Contains(result.stderr, `invalid ticket "EVERY-1;touch-pwned"`) || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func TestPrepareMissingMirrorUsesWorktrunkAndNoEnvironment(t *testing.T) {
	home, path, log := mirrorFixture(t)
	result := runEnv(t, home, path, []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315"}, "sync", "--prepare", "EVERY-3315")
	if result.err != nil || !strings.Contains(result.stdout, "prepared files, Git metadata, and sync without dependency") {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "ssh|", "git|-C "+filepath.Join(home, "work/lovable")+" fetch", "wt|-C "+filepath.Join(home, "work/lovable")+" switch --create daphen/every-3315", "rsync|-a --delete", "mutagen|sync create", "mutagen|sync flush")
	for _, forbidden := range []string{"direnv|", "checkout --force", "clean -qfd"} {
		if strings.Contains(calls, forbidden) {
			t.Fatalf("navigation ran %q:\n%s", forbidden, calls)
		}
	}
}

func TestPrepareRefreshesComparisonBaseBeforeReportingReady(t *testing.T) {
	for _, fail := range []bool{false, true} {
		home, path, log := mirrorFixture(t)
		makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
		extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching"}
		if fail {
			extra = append(extra, "FAIL_TRUNK=yes")
		}
		result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
		calls := readLog(t, log)
		if fail {
			if result.err == nil || !strings.Contains(result.stderr, "could not refresh origin/main") || strings.Contains(calls, "mutagen|sync flush") || strings.Contains(result.stdout, "prepared files") {
				t.Fatalf("stale base reported ready: result=%+v calls=%s", result, calls)
			}
		} else {
			if result.err != nil {
				t.Fatalf("result=%+v", result)
			}
			inOrder(t, calls, "fetch --quiet --no-tags origin refs/heads/main:refs/remotes/origin/main", "fetch --quiet --no-tags ssh://", "mutagen|sync flush")
		}
	}
}

func TestPrepareExcludesMergedMainChangesFromTicketDiff(t *testing.T) {
	home, path, _ := mirrorFixture(t)
	repo := filepath.Join(home, "work/lovable")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, repo, "init", "-b", "main")
	runGit(t, repo, "config", "user.name", "Test")
	runGit(t, repo, "config", "user.email", "test@example.com")
	runGit(t, repo, "commit", "--allow-empty", "-m", "old main")
	old := strings.TrimSpace(runGit(t, repo, "rev-parse", "HEAD"))
	for _, file := range []string{"unrelated.txt", "ticket.txt"} {
		if file == "ticket.txt" {
			runGit(t, repo, "switch", "-c", "daphen/every-3315")
		}
		if err := os.WriteFile(filepath.Join(repo, file), []byte(file), 0o644); err != nil {
			t.Fatal(err)
		}
		runGit(t, repo, "add", file)
		runGit(t, repo, "commit", "-m", file)
	}
	runGit(t, repo, "remote", "add", "origin", ".")
	runGit(t, repo, "update-ref", "refs/remotes/origin/main", old)
	if got := runGit(t, repo, "diff", "--name-only", "origin/main...HEAD"); !strings.Contains(got, "unrelated.txt") {
		t.Fatalf("fixture did not reproduce stale-base pollution: %s", got)
	}
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	realGit, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	head := strings.TrimSpace(runGit(t, repo, "rev-parse", "HEAD"))
	result := runEnv(t, home, path, []string{"VMHEAD=" + head, "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching", "VMCTL_REAL_GIT=" + realGit}, "sync", "--prepare", "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	if got := strings.TrimSpace(runGit(t, repo, "diff", "--name-only", "origin/main...HEAD")); got != "ticket.txt" {
		t.Fatalf("prepared comparison includes non-ticket changes: %s", got)
	}
}

func TestInitialSeedAppliesVMDeletionBeforeTwoWayCreation(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315", "SEED_DELETE=yes"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	localDeleted := filepath.Join(home, "work/lovable.daphen-every-3315/deleted-on-vm.ts")
	if pathExists(localDeleted) {
		t.Fatalf("one-way seed left VM-deleted tracked file at %s", localDeleted)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "rsync|-a --delete", "mutagen|sync create")
	if !strings.Contains(calls, ":/home/david_karlsson_lovable_dev/src/lovable-every-3315/ "+filepath.Join(home, "work/lovable.daphen-every-3315")+"/") {
		t.Fatalf("seed was not VM-to-local only:\n%s", calls)
	}
}

func TestPrepareCanonicalCwdKeepsSuffixedVMBranchAtCanonicalPath(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=488872b96a9dfcc9a0d00866d565b3fdb904e8fe", "VMBRANCH=daphen/every-3064-specimen-ack"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3064")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	if !strings.Contains(calls, "switch --create daphen/every-3064-specimen-ack --base 488872b") || !strings.Contains(calls, "worktree-path="+filepath.Join(home, "work/lovable.daphen-every-3064")) {
		t.Fatalf("canonical destination lost branch identity:\n%s", calls)
	}
}

func TestSuccessfulEmptyMutagenListCreatesSession(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=empty-success"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err != nil || !strings.Contains(readLog(t, log), "mutagen|sync create") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestPrepareRecoversOnlyCleanExactIncompleteCheckout(t *testing.T) {
	home, path, log := mirrorFixture(t)
	local := filepath.Join(home, "work/lovable.daphen-every-3315")
	makeGitMarker(t, local)
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "LOCALHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	calls := readLog(t, log)
	if result.err != nil || !strings.Contains(calls, "mutagen|sync create") || strings.Contains(calls, "wt|") || strings.Contains(calls, "rsync|") {
		t.Fatalf("result=%+v calls=%s", result, calls)
	}
}

func TestPrepareRefusesIncompleteCheckoutOwnedByAnotherRepository(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "LOCALHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "COMMON_GIT_DIR=/other/repository/.git"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "checkout is not owned") || strings.Contains(readLog(t, log), "mutagen|sync create") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestPrepareRefusesDirtyIncompleteCheckout(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "LOCALHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "WORKDIRTY=yes"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "local changes require explicit repair") || strings.Contains(readLog(t, log), "mutagen|sync create") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestRepairIncompleteMirror(t *testing.T) {
	home, path, local, head, object := repairFixture(t)
	result := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--repair", "image.png", filepath.Base(object), "19", "EVERY-3315")
	if result.err != nil || strings.TrimSpace(runGit(t, local, "branch", "--show-current")) != "daphen/every-3315" || runGit(t, local, "status", "--porcelain") != "" {
		t.Fatalf("result=%+v status=%s", result, runGit(t, local, "status", "--porcelain"))
	}
	bytes, _ := os.ReadFile(filepath.Join(local, "image.png"))
	if string(bytes) != "verified png bytes\n" || !strings.Contains(result.stdout, "verified local LFS objects") || !pathExists(object) {
		t.Fatalf("repair did not materialize verified LFS bytes: %q", bytes)
	}
}

func TestRefreshIgnoredAssetAndRefuseModifiedBytes(t *testing.T) {
	home, path, local, head, _ := repairFixture(t)
	old := []byte("stale ignored bytes\n")
	os.WriteFile(filepath.Join(local, "image.png"), old, 0o644)
	os.WriteFile(filepath.Join(path, "mutagen"), []byte("#!/bin/sh\nprintf '%s\\n' '"+matchingSessionJSON(home)+"'\n"), 0o755)
	oldHash := fmt.Sprintf("%x", sha256.Sum256(old))
	newHash := fmt.Sprintf("%x", sha256.Sum256([]byte("verified png bytes\n")))
	result := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--refresh-ignored", "image.png", oldHash, newHash, "EVERY-3315")
	if result.err != nil || string(mustRead(t, filepath.Join(local, "image.png"))) != "verified png bytes\n" {
		t.Fatalf("result=%+v", result)
	}
	os.WriteFile(filepath.Join(local, "image.png"), old, 0o644)
	raced := runEnv(t, home, path, []string{"VMHEAD=" + head, "MUTATE_DURING_QUERY=yes"}, "sync", "--refresh-ignored", "image.png", oldHash, newHash, "EVERY-3315")
	if raced.err == nil || string(mustRead(t, filepath.Join(local, "image.png"))) != "raced edit\n" {
		t.Fatalf("raced edit was overwritten: %+v", raced)
	}
	os.WriteFile(filepath.Join(local, "image.png"), []byte("personal edit\n"), 0o644)
	result = runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--refresh-ignored", "image.png", oldHash, newHash, "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "local bytes changed") || string(mustRead(t, filepath.Join(local, "image.png"))) != "personal edit\n" {
		t.Fatalf("modified asset was not preserved: %+v", result)
	}
	os.WriteFile(filepath.Join(local, "image.png"), old, 0o644)
	failedDelete := runEnv(t, home, path, []string{"VMHEAD=" + head, "LS_TREE_FAIL=yes"}, "sync", "--refresh-ignored", "image.png", oldHash, "-", "EVERY-3315")
	if failedDelete.err == nil || !pathExists(filepath.Join(local, "image.png")) {
		t.Fatalf("unproven deletion changed asset: %+v", failedDelete)
	}
	outside := filepath.Join(local, "../outside.png")
	os.WriteFile(outside, old, 0o644)
	for _, invalid := range []string{"../outside.png", "/tmp/outside.png"} {
		if got := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--refresh-ignored", invalid, oldHash, newHash, "EVERY-3315"); got.err == nil {
			t.Fatalf("unsafe path accepted: %s", invalid)
		}
	}
	os.Remove(filepath.Join(local, "image.png"))
	os.Symlink(outside, filepath.Join(local, "image.png"))
	if got := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--refresh-ignored", "image.png", oldHash, newHash, "EVERY-3315"); got.err == nil || string(mustRead(t, outside)) != string(old) {
		t.Fatal("symlink asset accepted or target changed")
	}
	os.Remove(filepath.Join(local, "image.png"))
	os.WriteFile(filepath.Join(local, "image.png"), old, 0o644)
	runGit(t, local, "add", "image.png")
	if got := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--refresh-ignored", "image.png", oldHash, newHash, "EVERY-3315"); got.err == nil || !strings.Contains(got.stderr, "staged changes") {
		t.Fatalf("staged asset accepted: %+v", got)
	}
}

func TestRepairRequiresMutagenIgnoredPath(t *testing.T) {
	home, path, local, head, object := repairFixture(t)
	result := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--repair", "extra.ts", filepath.Base(object), "19", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "non-ignored LFS specification") || strings.TrimSpace(runGit(t, local, "branch", "--show-current")) != "" {
		t.Fatalf("result=%+v", result)
	}
}

func TestRepairIncompleteMirrorRefusals(t *testing.T) {
	cases := []struct {
		name, want string
		alter      func(string, string, string)
	}{
		{"unrelated", "unrelated or staged", func(_, local, _ string) { os.WriteFile(filepath.Join(local, "extra.ts"), []byte("changed\n"), 0o644) }},
		{"staged", "unrelated or staged", func(_, local, _ string) {
			os.WriteFile(filepath.Join(local, "staged.ts"), []byte("x\n"), 0o644)
			runGit(t, local, "add", "staged.ts")
		}},
		{"dirty VM", "VM checkout is not clean", func(home, _, _ string) { os.WriteFile(filepath.Join(home, "vm-dirty"), []byte("1"), 0o644) }},
		{"wrong ownership", "not owned", func(home, local, _ string) {
			marker, _ := os.ReadFile(filepath.Join(local, ".git"))
			gitdir := strings.TrimSpace(strings.TrimPrefix(string(marker), "gitdir: "))
			os.MkdirAll(filepath.Join(home, "other.git"), 0o755)
			os.WriteFile(filepath.Join(gitdir, "commondir"), []byte(filepath.Join(home, "other.git")+"\n"), 0o644)
		}},
		{"wrong head", "expected detached HEAD", func(home, _, _ string) { os.WriteFile(filepath.Join(home, "wrong-head"), []byte("1"), 0o644) }},
		{"existing branch", "expected absent branch", func(_, local, _ string) { runGit(t, local, "branch", "daphen/every-3315") }},
		{"missing LFS", "object missing", func(_, _, object string) { os.Remove(object) }},
		{"bad LFS", "object is invalid", func(_, _, object string) { os.WriteFile(object, []byte("bad"), 0o644) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			home, path, local, head, object := repairFixture(t)
			tc.alter(home, local, object)
			if pathExists(filepath.Join(home, "wrong-head")) {
				head = strings.Repeat("4", 40)
			}
			result := runEnv(t, home, path, []string{"VMHEAD=" + head}, "sync", "--repair", "image.png", filepath.Base(object), "19", "EVERY-3315")
			branch := ""
			if tc.name != "wrong ownership" {
				branch = strings.TrimSpace(runGit(t, local, "branch", "--show-current"))
			}
			if result.err == nil || !strings.Contains(result.stderr, tc.want) || branch != "" {
				t.Fatalf("result=%+v branch=%q", result, branch)
			}
		})
	}
}

func TestPrepareDistinguishesMutagenQueryFailureFromAbsentSession(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=list-error"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	calls := readLog(t, log)
	if result.err == nil || !strings.Contains(result.stderr, "cannot inspect Mutagen sessions") || strings.Contains(calls, "wt|") || strings.Contains(calls, "rsync|") {
		t.Fatalf("result=%+v calls=%s", result, calls)
	}
}

func TestPrepareRequiresPostFlushMutagenReadiness(t *testing.T) {
	cases := []struct {
		name string
		env  string
	}{
		{"paused", "MUTAGEN_PAUSED=true"},
		{"not-watching", "MUTAGEN_STATUS=connecting"},
		{"alpha-disconnected", "ALPHA_CONNECTED=false"},
		{"alpha-unscanned", "ALPHA_SCANNED=false"},
		{"beta-disconnected", "BETA_CONNECTED=false"},
		{"beta-unscanned", "BETA_SCANNED=false"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			home, path, _ := mirrorFixture(t)
			extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=unhealthy", tc.env}
			result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
			if result.err == nil || !strings.Contains(result.stderr, "is not ready") || strings.Contains(result.stdout, "prepared files") {
				t.Fatalf("result=%+v", result)
			}
		})
	}
}

func TestPrepareRefusesWhenSessionDisappearsAfterFlush(t *testing.T) {
	home, path, _ := mirrorFixture(t)
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=disappear"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "disappeared after synchronization") || strings.Contains(result.stdout, "prepared files") {
		t.Fatalf("result=%+v", result)
	}
}

func TestSyncPreflightsGitLFS(t *testing.T) {
	home, path, log := mirrorFixture(t)
	if err := os.Remove(filepath.Join(path, "git-lfs")); err != nil {
		t.Fatal(err)
	}
	result := runEnv(t, home, path, []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315"}, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "git-lfs is unavailable") || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestPrepareExplicitRegisteredCheckoutMapsSameCwd(t *testing.T) {
	home, path, log := mirrorFixture(t)
	remote := "/home/david_karlsson_lovable_dev/src/lovable.davidkarlsson-every-3315-safe-mirror"
	extra := []string{"VMHEAD=3333333333333333333333333333333333333333", "VMBRANCH=davidkarlsson/every-3315-safe-mirror"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "--remote-cwd", remote, "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	local := filepath.Join(home, "work", filepath.Base(remote))
	calls := readLog(t, log)
	for _, want := range []string{"test -d '" + remote + "'", "wt|-C " + filepath.Join(home, "work/lovable") + " switch --create davidkarlsson/every-3315-safe-mirror", "--name=vmwt-davidkarlsson-every-3315-safe-mirror", remote, local} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls missing %q:\n%s", want, calls)
		}
	}
}

func TestAlignManagedMirrorPreservesDirtyStagedAndLocalFiles(t *testing.T) {
	home, path, log := mirrorFixture(t)
	local := filepath.Join(home, "work/lovable.daphen-every-3315")
	makeGitMarker(t, local)
	protected := filepath.Join(local, "protected.ts")
	if err := os.WriteFile(protected, []byte("local bytes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "LOCALHEAD=1111111111111111111111111111111111111111", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching"}
	result := runEnv(t, home, path, extra, "sync", "--align", "EVERY-3315")
	if result.err != nil || !strings.Contains(result.stdout, "working files preserved") {
		t.Fatalf("result=%+v", result)
	}
	data, _ := os.ReadFile(protected)
	if string(data) != "local bytes\n" {
		t.Fatalf("local bytes changed: %q", data)
	}
	calls := readLog(t, log)
	if !strings.Contains(calls, "reset --mixed 4444444444444444444444444444444444444444") || strings.Contains(calls, "checkout --force") || strings.Contains(calls, "clean -qfd") || strings.Contains(calls, "rsync|") {
		t.Fatalf("unsafe metadata alignment:\n%s", calls)
	}
}

func TestAlignRefusesMismatchedMutagenEndpoints(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=mismatch"}
	result := runEnv(t, home, path, extra, "sync", "--align", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "mismatched endpoints") || strings.Contains(readLog(t, log), "reset --mixed") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestPrepareRefusesLegacyUnanchoredBazelIgnore(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=stale-ignore"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "repair stale paths explicitly") || strings.Contains(readLog(t, log), "sync resume") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestAlignRefusesToDiscardIntentionalStaging(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "LOCALHEAD=1111111111111111111111111111111111111111", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching", "STAGED=yes"}
	result := runEnv(t, home, path, extra, "sync", "--align", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "staged changes") || strings.Contains(readLog(t, log), "reset --mixed") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestRealLifecycleCreatesSeedsAlignsAndReusesCanonicalMirror(t *testing.T) {
	home := t.TempDir()
	bin, repo, vm := filepath.Join(home, "bin"), filepath.Join(home, "work/lovable"), filepath.Join(home, "vm/lovable")
	local, state, log := filepath.Join(home, "work/lovable.daphen-every-3064"), filepath.Join(home, "mutagen-created"), filepath.Join(home, "calls.log")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	gitPath, _ := exec.LookPath("git")
	wtPath, err := exec.LookPath("wt")
	if err != nil {
		wtPath = "/etc/profiles/per-user/daphen/bin/wt"
	}
	rsyncPath, err := exec.LookPath("rsync")
	if err != nil {
		t.Fatal(err)
	}
	for name, target := range map[string]string{"git": gitPath, "wt": wtPath} {
		if err := os.Symlink(target, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	runGit(t, "", "init", "-q", "-b", "main", repo)
	runGit(t, repo, "remote", "add", "origin", ".")
	runGit(t, repo, "config", "user.email", "vmctl@test")
	runGit(t, repo, "config", "user.name", "vmctl test")
	for name, content := range map[string]string{"kept.ts": "base\n", "removed.ts": "remove\n"} {
		if err := os.WriteFile(filepath.Join(repo, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-qm", "base")
	runGit(t, "", "clone", "-q", repo, vm)
	runGit(t, vm, "config", "user.email", "vmctl@test")
	runGit(t, vm, "config", "user.name", "vmctl test")
	runGit(t, vm, "switch", "-qc", "daphen/every-3064-specimen-ack")
	if err := os.Remove(filepath.Join(vm, "removed.ts")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vm, "dirty.ts"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	uploadPack, _ := exec.LookPath("git-upload-pack")
	ssh := fmt.Sprintf("#!/bin/sh\ncase \"$*\" in *git-upload-pack*) exec %q %q ;; *branch\\ --show-current*) git -C %q rev-parse HEAD; git -C %q branch --show-current ;; *) git -C %q rev-parse HEAD ;; esac\n", uploadPack, vm, vm, vm, vm)
	listing := fmt.Sprintf(`[{"name":"vmwt-every-3064","alpha":{"protocol":"ssh","user":"david_karlsson_lovable_dev","host":"dev-heidr-2a39.workstation.lovable.net","path":"/home/david_karlsson_lovable_dev/src/lovable-every-3064","connected":true,"scanned":true},"beta":{"protocol":"local","path":%q,"connected":true,"scanned":true},"paused":false,"status":"watching"}]`, local)
	mutagen := fmt.Sprintf("#!/bin/sh\necho \"mutagen|$*\" >> %q\ncase \"$*\" in\n 'sync list --template '*) [ -f %q ] && printf '%%s\\n' '%s' || echo '[]' ;;\n 'sync create '*) : > %q ;;\n 'sync flush '*) exec %q -a --delete --exclude=.git %q/ %q/ ;;\nesac\n", log, state, listing, state, rsyncPath, vm, local)
	rsync := fmt.Sprintf("#!/bin/sh\necho \"rsync|$*\" >> %q\nexec %q -a --delete --exclude=.git %q/ %q/\n", log, rsyncPath, vm, local)
	for name, script := range map[string]string{"git-lfs": "#!/bin/sh\nexit 0\n", "ssh": ssh, "mutagen": mutagen, "rsync": rsync} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	first := runEnv(t, home, bin, nil, "sync", "--prepare", "EVERY-3064")
	if first.err != nil {
		t.Fatalf("first prepare=%+v", first)
	}
	if branch := strings.TrimSpace(runGit(t, local, "branch", "--show-current")); branch != "daphen/every-3064-specimen-ack" {
		t.Fatalf("branch=%q", branch)
	}
	if status := runGit(t, local, "status", "--porcelain"); !strings.Contains(status, " D removed.ts") || !strings.Contains(status, "?? dirty.ts") {
		t.Fatalf("initial seed status:\n%s", status)
	}
	if err := os.WriteFile(filepath.Join(vm, "kept.ts"), []byte("advanced\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, vm, "add", "-A")
	runGit(t, vm, "commit", "-qm", "advance")
	second := runEnv(t, home, bin, nil, "sync", "--prepare", "EVERY-3064")
	if second.err != nil {
		t.Fatalf("repeat prepare=%+v", second)
	}
	if status := runGit(t, local, "status", "--porcelain"); status != "" {
		t.Fatalf("repeat status:\n%s", status)
	}
	if got, want := strings.TrimSpace(runGit(t, local, "rev-parse", "HEAD")), strings.TrimSpace(runGit(t, vm, "rev-parse", "HEAD")); got != want {
		t.Fatalf("heads local=%s VM=%s", got, want)
	}
	calls, _ := os.ReadFile(log)
	if strings.Count(string(calls), "rsync|") != 1 || strings.Count(string(calls), "sync create") != 1 {
		t.Fatalf("repeat recreated/reseeded:\n%s", calls)
	}
}

func TestAlignCleanVMAdvanceRefreshesIndexWithRealGit(t *testing.T) {
	home := t.TempDir()
	bin, repo, mirror := filepath.Join(home, "bin"), filepath.Join(home, "work/lovable"), filepath.Join(home, "work/lovable.daphen-every-3315")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	gitPath, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(gitPath, filepath.Join(bin, "git")); err != nil {
		t.Fatal(err)
	}
	runGit(t, "", "init", "-q", "-b", "main", repo)
	runGit(t, repo, "remote", "add", "origin", ".")
	runGit(t, repo, "config", "user.email", "vmctl@test")
	runGit(t, repo, "config", "user.name", "vmctl test")
	if err := os.WriteFile(filepath.Join(repo, "kept.ts"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "removed.ts"), []byte("remove\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-qm", "base")
	base := strings.TrimSpace(runGit(t, repo, "rev-parse", "HEAD"))
	runGit(t, repo, "switch", "-qc", "daphen/every-3315")
	if err := os.WriteFile(filepath.Join(repo, "kept.ts"), []byte("advanced\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(repo, "removed.ts")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "added.ts"), []byte("added\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, repo, "add", "-A")
	runGit(t, repo, "commit", "-qm", "advance")
	head := strings.TrimSpace(runGit(t, repo, "rev-parse", "HEAD"))
	runGit(t, "", "clone", "-q", repo, mirror)
	runGit(t, mirror, "checkout", "-q", base)
	if err := os.WriteFile(filepath.Join(mirror, "kept.ts"), []byte("advanced\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(mirror, "removed.ts")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mirror, "added.ts"), []byte("added\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	uploadPack, err := exec.LookPath("git-upload-pack")
	if err != nil {
		t.Fatal(err)
	}
	ssh := fmt.Sprintf("#!/bin/sh\ncase \"$*\" in *git-upload-pack*) exec %q %q ;; esac\nprintf '%%s\\n%%s\\n' \"$VMHEAD\" daphen/every-3315\n", uploadPack, repo)
	if err := os.WriteFile(filepath.Join(bin, "ssh"), []byte(ssh), 0o755); err != nil {
		t.Fatal(err)
	}
	mutagen := fmt.Sprintf("#!/bin/sh\ncase \"$*\" in 'sync list --template '*) printf '%%s\\n' '%s' ;; 'sync flush '*) [ \"${FAIL_FLUSH-}\" != yes ] ;; esac\n", matchingSessionJSON(home))
	for name, script := range map[string]string{"git-lfs": "#!/bin/sh\nexit 0\n", "mutagen": mutagen, "wt": "#!/bin/sh\nexit 99\n", "rsync": "#!/bin/sh\nexit 99\n"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	treeBefore := strings.TrimSpace(runGit(t, mirror, "write-tree"))
	failed := runEnv(t, home, bin, []string{"VMHEAD=" + head, "FAIL_FLUSH=yes"}, "sync", "--prepare", "EVERY-3315")
	if failed.err == nil || !strings.Contains(failed.stderr, "Mutagen synchronization failed") || strings.TrimSpace(runGit(t, mirror, "rev-parse", "HEAD")) != base || strings.TrimSpace(runGit(t, mirror, "write-tree")) != treeBefore {
		t.Fatalf("failed flush changed metadata: result=%+v", failed)
	}
	result := runEnv(t, home, bin, []string{"VMHEAD=" + head}, "sync", "--align", "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	if status := runGit(t, mirror, "status", "--porcelain"); status != "" {
		t.Fatalf("stale index after alignment:\n%s", status)
	}
	want := "A\tadded.ts\nM\tkept.ts\nD\tremoved.ts\n"
	if diff := runGit(t, mirror, "diff", "--name-status", base, "HEAD"); diff != want {
		t.Fatalf("PR diff=%q want=%q", diff, want)
	}
}

func TestAlignRefusesDivergentHeads(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "LOCALHEAD=1111111111111111111111111111111111111111", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching", "DIVERGED=yes"}
	result := runEnv(t, home, path, extra, "sync", "--align", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "diverges") || strings.Contains(readLog(t, log), "reset --mixed") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestFirstSeedRefreshesStatsOnlyForProvenEmptyDiff(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "diff --cached --quiet", "diff --no-ext-diff --no-textconv --quiet", "write-tree", "add --update", "write-tree")

	dirtyHome, dirtyPath, dirtyLog := mirrorFixture(t)
	dirty := append(extra, "WORKDIRTY=yes")
	result = runEnv(t, dirtyHome, dirtyPath, dirty, "sync", "--prepare", "EVERY-3315")
	if result.err != nil || strings.Contains(readLog(t, dirtyLog), "add --update") {
		t.Fatalf("dirty seed refreshed stats: result=%+v calls=%s", result, readLog(t, dirtyLog))
	}
}

func TestNewSyncAnchorsBazelBuildIgnoreAtRoot(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	if !strings.Contains(calls, "--ignore=/bazel-*") || strings.Contains(calls, "--ignore=bazel-*") {
		t.Fatalf("nested tracked Bazel source would be ignored:\n%s", calls)
	}
	for _, pattern := range []string{".envrc.local", ".env.local", ".env"} {
		if !strings.Contains(calls, "rsync|-a --delete") || !strings.Contains(calls, "--exclude="+pattern) || !strings.Contains(calls, "--ignore="+pattern) {
			t.Fatalf("machine-local %s was not excluded from seed and sync:\n%s", pattern, calls)
		}
	}
}

func TestInitialSeedFailureCannotEnableTwoWaySync(t *testing.T) {
	home, path, log := mirrorFixture(t)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315", "FAIL_SEED=yes"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "initial one-way mirror seed failed") || strings.Contains(readLog(t, log), "mutagen|sync create") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestPrepareMovedVMHeadDoesNotAlignOrReportReady(t *testing.T) {
	home, path, log := mirrorFixture(t)
	makeGitMarker(t, filepath.Join(home, "work/lovable.daphen-every-3315"))
	extra := []string{"VMHEAD=4444444444444444444444444444444444444444", "VMHEAD_AFTER=5555555555555555555555555555555555555555", "LOCALHEAD=1111111111111111111111111111111111111111", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	calls := readLog(t, log)
	if result.err == nil || !strings.Contains(result.stderr, "VM HEAD moved during sync") || strings.Contains(calls, "reset --mixed") || strings.Contains(result.stdout, "prepared files") {
		t.Fatalf("result=%+v calls=%s", result, calls)
	}
}

func TestPrepareSurfacesMutagenSyncFailure(t *testing.T) {
	home, path, _ := mirrorFixture(t)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315", "FAIL_FLUSH=yes"}
	result := runEnv(t, home, path, extra, "sync", "--prepare", "EVERY-3315")
	if result.err == nil || !strings.Contains(result.stderr, "Mutagen synchronization failed") {
		t.Fatalf("result=%+v", result)
	}
}

func TestFullSyncRetainsCheckedDependencySetup(t *testing.T) {
	home, path, log := mirrorFixture(t)
	local := filepath.Join(home, "work/lovable.daphen-every-3315")
	makeGitMarker(t, local)
	writePackage(t, local)
	extra := []string{"VMHEAD=2222222222222222222222222222222222222222", "LOCALHEAD=2222222222222222222222222222222222222222", "VMBRANCH=daphen/every-3315", "MUTAGEN_MODE=matching"}
	result := runEnv(t, home, path, extra, "sync", "EVERY-3315")
	if result.err != nil {
		t.Fatalf("result=%+v", result)
	}
	inOrder(t, readLog(t, log), "mutagen|sync flush", "direnv|allow "+local, "direnv|exec "+local+" pnpm install --frozen-lockfile --prefer-offline", "direnv|exec "+local+" pnpm --dir web run paraglide:build")
}

func mirrorFixture(t *testing.T) (string, string, string) {
	t.Helper()
	body := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
matching_mutagen() {
  session=vmwt-every-3315; remote=/home/david_karlsson_lovable_dev/src/lovable-every-3315; local=$HOME/work/lovable.daphen-every-3315
  [ ! -s "$HOME/mutagen-name" ] || read -r session < "$HOME/mutagen-name"
  [ ! -s "$HOME/mutagen-remote" ] || read -r remote < "$HOME/mutagen-remote"
  [ ! -s "$HOME/mutagen-local" ] || read -r local < "$HOME/mutagen-local"
  printf '[{"name":"%s","alpha":{"protocol":"ssh","user":"david_karlsson_lovable_dev","host":"dev-heidr-2a39.workstation.lovable.net","path":"%s","connected":%s,"scanned":%s},"beta":{"protocol":"local","path":"%s","connected":%s,"scanned":%s},"paused":%s,"status":"%s"}]\n' "$session" "$remote" "${ALPHA_CONNECTED-true}" "${ALPHA_SCANNED-true}" "$local" "${BETA_CONNECTED-true}" "${BETA_SCANNED-true}" "${MUTAGEN_PAUSED-false}" "${MUTAGEN_STATUS-watching}"
}
case "$name" in
 ssh)
   case "$*" in
     *"branch --show-current"*) : > "$HOME/ssh-seen"; printf '%s\n%s\n' "${VMHEAD}" "${VMBRANCH}" ;;
     *) if [ -n "${VMHEAD_AFTER-}" ] && [ -f "$HOME/ssh-seen" ]; then echo "$VMHEAD_AFTER"; else echo "$VMHEAD"; fi ;;
   esac ;;
 git)
   case "$*" in
     *"fetch --quiet --no-tags origin refs/heads/main:refs/remotes/origin/main"*) [ "${FAIL_TRUNK-}" != yes ] || exit 1; [ -z "${VMCTL_REAL_GIT-}" ] || exec "$VMCTL_REAL_GIT" "$@" ;;
     *"rev-parse FETCH_HEAD"*) echo "${VMHEAD}" ;;
     *"rev-parse HEAD"*) echo "${LOCALHEAD-${VMHEAD}}" ;;
     *"rev-parse --show-toplevel"*) if [ -s "$HOME/wt-path" ]; then while IFS= read -r root; do echo "$root"; done < "$HOME/wt-path"; else echo "$HOME/work/lovable.daphen-every-3315"; fi ;;
     *"rev-parse --path-format=absolute --git-common-dir"*) echo "${COMMON_GIT_DIR-$HOME/work/lovable/.git}" ;;
     *"branch --show-current"*) echo "${LOCALBRANCH-${VMBRANCH}}" ;;
     *"status --porcelain"*) [ "${WORKDIRTY-}" != yes ] || echo '?? local-change.ts' ;;
     *"show-ref --verify"*) exit 1 ;;
     *"merge-base --is-ancestor"*) [ "${DIVERGED-}" != yes ] ;;
     *"diff --cached --quiet"*) [ "${STAGED-}" != yes ] ;;
     *"diff --no-ext-diff --no-textconv --quiet"*) [ "${WORKDIRTY-}" != yes ] ;;
     *"write-tree"*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
   esac ;;
 wt) echo "worktree-path=$WORKTRUNK_WORKTREE_PATH" >> "$VMCTL_LOG"; echo "$WORKTRUNK_WORKTREE_PATH" > "$HOME/wt-path"; mkdir -p "$WORKTRUNK_WORKTREE_PATH"; : > "$WORKTRUNK_WORKTREE_PATH/.git"; [ "${SEED_DELETE-}" != yes ] || echo stale > "$WORKTRUNK_WORKTREE_PATH/deleted-on-vm.ts" ;;
 rsync) [ "${FAIL_SEED-}" != yes ] || exit 8; [ "${SEED_DELETE-}" != yes ] || rm -f "$HOME/work/lovable.daphen-every-3315/deleted-on-vm.ts" ;;
 mutagen)
   case "$*" in
     "sync list --template "*)
       [ "${MUTAGEN_MODE-}" = list-error ] && exit 7
       [ "${MUTAGEN_MODE-}" = disappear ] && echo '[]' && exit 0
       [ "${MUTAGEN_MODE-}" = mismatch ] && printf '[{"name":"vmwt-every-3315","alpha":{"protocol":"ssh","user":"other","host":"wrong","path":"/wrong"},"beta":{"protocol":"local","path":"/wrong"}}]\n' && exit 0
       [ "${MUTAGEN_MODE-}" = stale-ignore ] && printf '[{"name":"vmwt-every-3315","alpha":{"protocol":"ssh","user":"david_karlsson_lovable_dev","host":"dev-heidr-2a39.workstation.lovable.net","path":"/home/david_karlsson_lovable_dev/src/lovable-every-3315"},"beta":{"protocol":"local","path":"%s/work/lovable.daphen-every-3315"},"ignore":{"paths":["bazel-*"]}}]\n' "$HOME" && exit 0
       if [ "${MUTAGEN_MODE-}" = matching ] || [ "${MUTAGEN_MODE-}" = unhealthy ] || [ -f "$HOME/mutagen-created" ]; then matching_mutagen; else echo '[]'; fi ;;
     "sync create "*)
       previous=; before_previous=
       for argument in "$@"; do
         case "$argument" in --name=*) printf '%s\n' "${argument#--name=}" > "$HOME/mutagen-name" ;; esac
         before_previous=$previous; previous=$argument
       done
       printf '%s\n' "${before_previous#*:}" > "$HOME/mutagen-remote"
       printf '%s\n' "$previous" > "$HOME/mutagen-local"
       : > "$HOME/mutagen-created" ;;
     "sync flush "*) [ "${FAIL_FLUSH-}" != yes ] ;;
   esac ;;
 esac
`
	return fixture(t, body)
}

func repairFixture(t *testing.T) (string, string, string, string, string) {
	t.Helper()
	home, _ := filepath.EvalSymlinks(t.TempDir())
	repo, local, bin := filepath.Join(home, "work/lovable"), filepath.Join(home, "work/lovable.daphen-every-3315"), filepath.Join(home, "bin")
	os.MkdirAll(repo, 0o755)
	runGit(t, repo, "init", "-b", "main")
	runGit(t, repo, "config", "user.email", "test@example.com")
	runGit(t, repo, "config", "user.name", "Test")
	runGit(t, repo, "lfs", "install", "--local")
	payload := []byte("verified png bytes\n")
	oid := fmt.Sprintf("%x", sha256.Sum256(payload))
	os.WriteFile(filepath.Join(repo, ".gitattributes"), []byte("*.png filter=lfs diff=lfs merge=lfs -text\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "image.png"), payload, 0o644)
	os.WriteFile(filepath.Join(repo, "extra.ts"), []byte("base\n"), 0o644)
	runGit(t, repo, "add", ".")
	object := filepath.Join(repo, ".git/lfs/objects", oid[:2], oid[2:4], oid)
	runGit(t, repo, "commit", "-m", "fixture")
	head := strings.TrimSpace(runGit(t, repo, "rev-parse", "HEAD"))
	runGit(t, repo, "worktree", "add", "--detach", local, head)
	os.Remove(filepath.Join(local, "image.png"))
	os.Mkdir(bin, 0o755)
	for _, name := range []string{"git", "git-lfs"} {
		target, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		os.Symlink(target, filepath.Join(bin, name))
	}
	ssh := "#!/bin/sh\ncase \"$*\" in *'branch --show-current'*) printf '%s\\n%s\\n' \"$VMHEAD\" daphen/every-3315;; *'status --porcelain'*) [ ! -f \"$HOME/vm-dirty\" ] || echo ' M remote.ts';; *'cat-file --filters'*) [ \"${MUTATE_DURING_QUERY-}\" != yes ] || printf 'raced edit\\n' > \"$HOME/work/lovable.daphen-every-3315/image.png\"; printf 'verified png bytes\\n';; *'ls-tree --name-only'*) [ \"${LS_TREE_FAIL-}\" != yes ];; esac\n"
	os.WriteFile(filepath.Join(bin, "ssh"), []byte(ssh), 0o755)
	os.WriteFile(filepath.Join(bin, "mutagen"), []byte("#!/bin/sh\necho '[]'\n"), 0o755)
	os.WriteFile(filepath.Join(bin, "wt"), []byte("#!/bin/sh\nexit 99\n"), 0o755)
	return home, bin, local, head, object
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return bytes
}

func matchingSessionJSON(home string) string {
	return fmt.Sprintf(`[{"name":"vmwt-every-3315","alpha":{"protocol":"ssh","user":"david_karlsson_lovable_dev","host":"dev-heidr-2a39.workstation.lovable.net","path":"/home/david_karlsson_lovable_dev/src/lovable-every-3315","connected":true,"scanned":true},"beta":{"protocol":"local","path":%q,"connected":true,"scanned":true},"paused":false,"status":"watching"}]`, filepath.Join(home, "work/lovable.daphen-every-3315"))
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	text, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, text)
	}
	return string(text)
}

func makeGitMarker(t *testing.T, local string) {
	t.Helper()
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(local, ".git"), []byte("gitdir: protected\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writePackage(t *testing.T, local string) {
	t.Helper()
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(local, "package.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
}

type result struct {
	stdout, stderr string
	err            error
}

func fixture(t *testing.T, body string) (string, string, string) {
	t.Helper()
	home, path := t.TempDir(), ""
	path = filepath.Join(home, "bin")
	log := filepath.Join(home, "calls.log")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"git", "git-lfs", "ssh", "mutagen", "wt", "rsync", "direnv"} {
		if err := os.WriteFile(filepath.Join(path, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"mkdir", "rm"} {
		command, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(command, filepath.Join(path, name)); err != nil {
			t.Fatal(err)
		}
	}
	return home, path, log
}

func run(t *testing.T, home, path string, args ...string) result {
	return runEnv(t, home, path, nil, args...)
}

func runEnv(t *testing.T, home, path string, extra []string, args ...string) result {
	t.Helper()
	cmd := exec.Command(binary, args...)
	cmd.Env = append(os.Environ(), append([]string{"HOME=" + home, "PATH=" + path, "VMCTL_LOG=" + filepath.Join(home, "calls.log")}, extra...)...)
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return result{stdout.String(), stderr.String(), err}
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	text, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(text)
}

func inOrder(t *testing.T, text string, wants ...string) {
	t.Helper()
	at := 0
	for _, want := range wants {
		next := strings.Index(text[at:], want)
		if next < 0 {
			t.Fatalf("%q missing after byte %d:\n%s", want, at, text)
		}
		at += next + len(want)
	}
}
