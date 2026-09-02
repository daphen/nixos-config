package main

import (
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
	cmd := exec.Command("go", "build", "-o", binary, ".")
	if text, err := cmd.CombinedOutput(); err != nil {
		panic(string(text))
	}
	os.Exit(m.Run())
}

func TestRejectsTicketBeforeInterpolation(t *testing.T) {
	home, path, log := fixture(t, ``)
	result := run(t, home, path, "sync", "EVERY-1;touch-pwned")
	if result.err == nil || !strings.Contains(result.stderr, `invalid ticket "EVERY-1;touch-pwned"`) {
		t.Fatalf("stderr=%q err=%v", result.stderr, result.err)
	}
	if text, _ := os.ReadFile(log); len(text) != 0 {
		t.Fatalf("ran an external command: %s", text)
	}
}

func TestSyncRunsPortedFlow(t *testing.T) {
	script := `
name=${0##*/}
echo "$name|$*|${GIT_SSH_COMMAND-}" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" cat-file -e "*) exit 0 ;;
  "git|"*" status --porcelain") echo ' M src/app.ts' ;;
  "git|"*" diff --shortstat") echo ' 1 file changed, 2 insertions(+)' ;;
  "git|"*" worktree add "*) /bin/mkdir -p "$6"; echo Preparing; echo 'HEAD is now at 0123456789a test' ;;
  "mutagen|sync list "*) exit 1 ;;
  "rsync|"*) echo 'Warning: fake host warning'; echo copied ;;
esac
`
	home, path, log := fixture(t, script)
	if err := os.MkdirAll(filepath.Join(home, "work", "lovable.daphen-every-2741"), 0o755); err != nil {
		t.Fatal(err)
	}
	result := run(t, home, path, "sync", "EvErY-2741")
	if result.err != nil {
		t.Fatalf("failed: %v\nstdout=%s\nstderr=%s", result.err, result.stdout, result.stderr)
	}
	for _, want := range []string{
		"VM head: 0123456789a", "HEAD is now at 0123456789a test", "copied",
		"create sync (two-way-resolved, VM wins)", " 1 file changed, 2 insertions(+)",
		"done — nvim gets gutter hunks",
	} {
		if !strings.Contains(result.stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, result.stdout)
		}
	}
	if strings.Contains(result.stdout, "Warning:") {
		t.Errorf("rsync warning was not filtered: %s", result.stdout)
	}
	calls := readLog(t, log)
	inOrder(t, calls,
		"ssh|-o StrictHostKeyChecking=no", "mutagen|sync pause vmwt-every-2741",
		"git|-C "+filepath.Join(home, "work/lovable")+" fetch -q --no-tags origin main",
		"git|-C "+filepath.Join(home, "work/lovable")+" cat-file -e",
		"git|-C "+filepath.Join(home, "work/lovable")+" worktree add --detach",
		"rsync|-a", "git|status --porcelain", "mutagen|sync list vmwt-every-2741",
		"mutagen|sync create", "git|-C "+filepath.Join(home, "work/lovable.daphen-every-2741")+" status --porcelain",
	)
	for _, want := range []string{
		"--watch-polling-interval=600", "--sync-mode=two-way-resolved", "--ignore=.git",
		"--ignore=*.sqlite-shm", "--ignore=*.png", "--ignore=!.heidr-pastes/**",
		"david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net:/home/david_karlsson_lovable_dev/src/lovable-every-2741",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls missing %q", want)
		}
	}
}

func TestAlignIsBestEffortAndUsesFallbackEnvironment(t *testing.T) {
	script := `
name=${0##*/}
echo "$name|$*|${GIT_SSH_COMMAND-}" >> "$VMCTL_LOG"
case "$name|$*" in
  "git|"*" merge-base "*) echo base ;;
  "git|"*" diff --name-only"*) i=1; while [ $i -le 151 ]; do echo "file-$i"; i=$((i+1)); done ;;
  "ssh|"*) echo fedcba9876543210fedcba9876543210fedcba98 ;;
  "git|"*" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" cat-file -e "*) exit 1 ;;
  "git|"*"ssh://legacy@legacy-host/home/legacy/src/lovable "*) exit 1 ;;
esac
`
	home, path, log := fixture(t, script)
	local := filepath.Join(home, "work", "lovable.daphen-every-9")
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	result := runEnv(t, home, path, []string{
		"COCKPIT_VM_USER=", "HEIDR_VM_USER=legacy", "COCKPIT_VM=", "HEIDR_VM=legacy-vm",
		"COCKPIT_VM_HOST=", "HEIDR_VM_HOST=legacy-host", "XDG_RUNTIME_DIR=" + filepath.Join(home, "run"),
	}, "sync", "--align", "EVERY-9")
	if result.err != nil {
		t.Fatalf("failed: %v stderr=%s", result.err, result.stderr)
	}
	if !strings.Contains(result.stdout, "[vm-sync] every-9: HEAD 0123456789a -> fedcba98765 (files untouched)") {
		t.Fatalf("unexpected stdout: %s", result.stdout)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "git|-C "+local+" merge-base", "git|-C "+local+" diff --name-only base",
		"git|-C "+local+" fetch -q --no-tags origin main", "ssh|-o StrictHostKeyChecking=no",
		"git|-C "+local+" rev-parse HEAD", "git|-C "+local+" cat-file -e",
		"git|-C "+local+" fetch -q ssh://legacy@legacy-host/home/legacy/src/lovable",
		"git|-C "+local+" fetch -q origin", "git|-C "+local+" reset -q")
	if !strings.Contains(calls, "ControlPersist=600") || !strings.Contains(calls, "ControlPath="+filepath.Join(home, "run", "heidr-vm-cm")) {
		t.Errorf("missing align SSH controls:\n%s", calls)
	}
}

func TestAlignSmallDiffSkipsNetwork(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "git|"*" merge-base "*) echo base ;;
  "git|"*" diff --name-only"*) echo changed.go ;;
esac
`
	home, path, log := fixture(t, script)
	if err := os.MkdirAll(filepath.Join(home, "work/lovable.daphen-every-10"), 0o755); err != nil {
		t.Fatal(err)
	}
	result := run(t, home, path, "sync", "--align", "every-10")
	if result.err != nil || result.stdout != "" {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	if strings.Contains(calls, "ssh|") || strings.Contains(calls, " fetch ") {
		t.Fatalf("small diff reached network:\n%s", calls)
	}
}

func TestAlignAbsentMirrorDoesNothing(t *testing.T) {
	home, path, log := fixture(t, `echo called >> "$VMCTL_LOG"`)
	result := run(t, home, path, "sync", "--align", "EVERY-11")
	if result.err != nil || result.stdout != "" || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func TestSyncExistingWorktreeChecksOutCleansAndResumes(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" cat-file -e "*) exit 0 ;;
  "mutagen|sync list "*) exit 0 ;;
esac
`
	home, path, log := fixture(t, script)
	local := filepath.Join(home, "work/lovable.daphen-every-12")
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(local, ".git"), []byte("gitdir: fake"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := run(t, home, path, "sync", "EVERY-12")
	if result.err != nil {
		t.Fatalf("failed: %v stderr=%s", result.err, result.stderr)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "checkout --force --detach", "clean -qfd", "rsync|-a", "mutagen|sync list", "mutagen|sync resume")
	if strings.Contains(calls, "worktree add") || strings.Contains(calls, "sync create") {
		t.Fatalf("used new-worktree path:\n%s", calls)
	}
}

func TestSyncMissingCommitTriesAllFetchSources(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*|${GIT_SSH_COMMAND-}" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" cat-file -e "*) exit 1 ;;
  "git|"*" fetch --quiet ssh://"*) exit 1 ;;
  "mutagen|sync list "*) exit 0 ;;
esac
`
	home, path, log := fixture(t, script)
	local := filepath.Join(home, "work/lovable.daphen-every-13")
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	result := run(t, home, path, "sync", "EVERY-13")
	if result.err != nil {
		t.Fatalf("failed: %v stderr=%s", result.err, result.stderr)
	}
	calls := readLog(t, log)
	inOrder(t, calls,
		"fetch --quiet ssh://david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net/home/david_karlsson_lovable_dev/src/lovable-every-13",
		"fetch --quiet ssh://david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net/home/david_karlsson_lovable_dev/src/lovable ",
		"fetch --quiet origin 0123456789abcdef")
	if strings.Count(calls, "|ssh -o StrictHostKeyChecking=no") != 2 {
		t.Fatalf("VM fetches did not receive SSH environment:\n%s", calls)
	}
}

func TestSyncMissingMutagenIsFatal(t *testing.T) {
	home, path, log := fixture(t, `echo called >> "$VMCTL_LOG"`)
	if err := os.Remove(filepath.Join(path, "mutagen")); err != nil {
		t.Fatal(err)
	}
	result := run(t, home, path, "sync", "EVERY-14")
	if result.err == nil || result.stderr != "✗ mutagen not on PATH\n" || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func TestMutagenCreateFailureIsBestEffort(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" cat-file -e "*) exit 0 ;;
  "mutagen|sync list "*|"mutagen|sync create "*) exit 1 ;;
esac
`
	home, path, log := fixture(t, script)
	if err := os.MkdirAll(filepath.Join(home, "work/lovable.daphen-every-15"), 0o755); err != nil {
		t.Fatal(err)
	}
	result := run(t, home, path, "sync", "EVERY-15")
	if result.err != nil || !strings.Contains(result.stdout, "✗ create failed") || !strings.Contains(result.stdout, "done — nvim") {
		t.Fatalf("result=%+v", result)
	}
	inOrder(t, readLog(t, log), "mutagen|sync list", "mutagen|sync create", "git|-C")
}

func TestAlignDependencyInstallDebounce(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "git|"*" merge-base "*) echo base ;;
  "git|"*" diff --name-only"*) echo changed.go ;;
esac
`
	home, path, log := fixture(t, script)
	local := filepath.Join(home, "work/lovable.daphen-every-16")
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"package.json", ".pnpm-install.log"} {
		if err := os.WriteFile(filepath.Join(local, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	result := run(t, home, path, "sync", "--align", "EVERY-16")
	calls := readLog(t, log)
	if result.err != nil || strings.Contains(calls, "direnv|") || strings.Contains(calls, "nohup|") {
		t.Fatalf("debounce failed: result=%+v calls=%s", result, calls)
	}
}

type result struct {
	stdout, stderr string
	err            error
}

func fixture(t *testing.T, body string) (string, string, string) {
	t.Helper()
	home := t.TempDir()
	path := filepath.Join(home, "bin")
	log := filepath.Join(home, "calls.log")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"git", "ssh", "mutagen", "rsync", "xargs", "direnv", "nohup"} {
		content := "#!/bin/sh\n" + body
		if err := os.WriteFile(filepath.Join(path, name), []byte(content), 0o755); err != nil {
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
