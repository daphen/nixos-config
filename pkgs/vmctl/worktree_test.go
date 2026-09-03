package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorktreeRequiresCockpitSocket(t *testing.T) {
	home, path, log := worktreeFixture(t, "")
	result := runWorktreeBinary(t, home, path, "EVERY-42")
	want := "✗ " + filepath.Join(home, "run", "agentd-work.sock") + " missing — run vm-cockpit first\n"
	if result.err == nil || result.stderr != want || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func TestWorktreeRestartMarkerStopsBeforeCommands(t *testing.T) {
	home, path, log := worktreeFixture(t, "")
	listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, nil)
	defer listener.Close()
	if err := os.WriteFile(filepath.Join(home, "run", "heidr-role-bundle-work.restart-required"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	result := runWorktreeBinary(t, home, path, "EVERY-43")
	if result.err == nil || result.stderr != "✗ role bundle updated, agentd restart required — do not spawn ticket sessions\n" || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func TestWorktreeRunsPortedFlowAndSpawnsAgent(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*"playwright"*) exit 1 ;;
  "ssh|"*) echo 'Warning: Permanently added fake'; echo '  remote ok' ;;
  "vm-sync|"*) echo sync-failed; exit 1 ;;
esac
`
	home, path, log := worktreeFixture(t, script)
	mirror := filepath.Join(home, "work", "lovable.daphen-every-44")
	if err := os.MkdirAll(mirror, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mirror, "package.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	messages := make(chan map[string]any, 1)
	listener, done := worktreeSocket(t, home, `{"sessions":[]}`, messages)
	defer listener.Close()

	result := runWorktreeBinary(t, home, path, "EvErY-44")
	if result.err != nil {
		t.Fatalf("failed: %v\nstdout=%s\nstderr=%s", result.err, result.stdout, result.stderr)
	}
	<-done
	message := <-messages
	if message["type"] != "spawn" || message["session"] != "every-44" || message["profile"] != "lovable-worker" ||
		message["cwd"] != "/home/tester/src/lovable-every-44" || message["prompt"] != "/skill:plan-ticket EVERY-44" {
		t.Fatalf("spawn=%#v", message)
	}
	for _, want := range []string{
		"worktree /home/tester/src/lovable-every-44 on daphen/every-44",
		"boot devenv wt in tmux session wt-every-44", "  sync-failed",
		"✗✗ NO LOCAL MIRROR", "retry with:  vm-sync EvErY-44",
		"pnpm install (background)", "✗ playwright override failed (non-fatal)",
		"spawned 'every-44' with the plan seed", "done — select 'every-44' in the rail",
	} {
		if !strings.Contains(result.stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, result.stdout)
		}
	}
	if strings.Contains(result.stdout, "Warning: Permanently") {
		t.Errorf("host warning leaked: %s", result.stdout)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "ssh|-o StrictHostKeyChecking=no", "git worktree add", "ssh|-o StrictHostKeyChecking=no", "tmux new-session",
		"vm-sync|EvErY-44", "direnv|allow .")
	for _, want := range []string{"nohup|direnv exec " + mirror, "nix develop ./nix-config --impure -c ./bin/devenv wt --no-meticulous", "@playwright/mcp@latest", "PLAYWRIGHT_BROWSERS_PATH", "grep -qx '.pi/'"} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls missing %q:\n%s", want, calls)
		}
	}
}

func TestWorktreeExistingAgentHistoryBehavior(t *testing.T) {
	for _, tc := range []struct {
		name, profile, entries, wantType, wantText string
	}{
		{"history", "lovable-worker", `{"type":"text","text":"started"}`, "get_entries", "already has history — not re-seeding"},
		{"empty", "lovable-worker", `{}`, "prompt", "existed but was empty — seeded"},
		{"wrong profile", "coding", `{}`, "", "expected 'lovable-worker'"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home, path, _ := worktreeFixture(t, `name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"`)
			mirror := filepath.Join(home, "work", "lovable.daphen-every-45")
			if err := os.MkdirAll(mirror, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(mirror, ".git"), nil, 0o644); err != nil {
				t.Fatal(err)
			}
			messages := make(chan map[string]any, 3)
			roster := `{"sessions":[{"name":"every-45","profile":"` + tc.profile + `"}]}`
			listener, done := worktreeAgentSocket(t, home, roster, tc.entries, messages)
			defer listener.Close()

			result := runWorktreeBinary(t, home, path, "EVERY-45")
			if tc.profile == "coding" {
				if result.err == nil || !strings.Contains(result.stderr, tc.wantText) {
					t.Fatalf("result=%+v", result)
				}
				return
			}
			<-done
			var types []string
			close(messages)
			for message := range messages {
				types = append(types, message["type"].(string))
			}
			if !strings.Contains(strings.Join(types, ","), tc.wantType) || !strings.Contains(result.stdout, tc.wantText) {
				t.Fatalf("types=%v result=%+v", types, result)
			}
			if tc.name == "history" && strings.Contains(strings.Join(types, ","), "prompt") {
				t.Fatalf("history was re-seeded: %v", types)
			}
		})
	}
}

func worktreeFixture(t *testing.T, body string) (string, string, string) {
	t.Helper()
	home := t.TempDir()
	path := filepath.Join(home, "bin")
	log := filepath.Join(home, "calls.log")
	if err := os.MkdirAll(filepath.Join(home, "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ssh", "direnv", "nohup", "vm-sync"} {
		if err := os.WriteFile(filepath.Join(path, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(home, ".local", "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(path, "vm-sync"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".local", "bin", "vm-sync"), data, 0o755); err != nil {
		t.Fatal(err)
	}
	return home, path, log
}

func worktreeSocket(t *testing.T, home, roster string, messages chan map[string]any) (net.Listener, <-chan struct{}) {
	t.Helper()
	return worktreeAgentSocket(t, home, roster, "", messages)
}

func worktreeAgentSocket(t *testing.T, home, roster, entries string, messages chan map[string]any) (net.Listener, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("unix", filepath.Join(home, "run", "agentd-work.sock"))
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = conn.Write([]byte(roster + "\n"))
		scanner := bufio.NewScanner(conn)
		for scanner.Scan() {
			var message map[string]any
			_ = json.Unmarshal(scanner.Bytes(), &message)
			if messages != nil {
				messages <- message
			}
			if message["type"] == "get_entries" {
				if entries != "" {
					_, _ = conn.Write([]byte(entries))
				}
				if strings.Contains(entries, `"type":"text"`) {
					return
				}
			}
			if message["type"] == "spawn" || message["type"] == "prompt" {
				return
			}
		}
	}()
	return listener, done
}

func runWorktreeBinary(t *testing.T, home, path, raw string) result {
	t.Helper()
	cmd := exec.Command(binary, "worktree", raw)
	cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+path, "VMCTL_LOG="+filepath.Join(home, "calls.log"),
		"XDG_RUNTIME_DIR="+filepath.Join(home, "run"), "COCKPIT_VM_USER=tester", "COCKPIT_VM_HOST=test-host")
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return result{stdout.String(), stderr.String(), err}
}
