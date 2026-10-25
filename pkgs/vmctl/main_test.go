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
	for _, key := range []string{"COCKPIT_AGENT_PROFILE", "HEIDR_AGENT_PROFILE"} {
		os.Unsetenv(key)
	}
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
	result := run(t, home, path, "worktree", "EVERY-1;touch-pwned")
	if result.err == nil || !strings.Contains(result.stderr, `invalid ticket "EVERY-1;touch-pwned"`) || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return bytes
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
	for _, name := range []string{"git", "ssh", "rsync", "direnv"} {
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
