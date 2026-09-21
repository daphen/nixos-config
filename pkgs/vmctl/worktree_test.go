package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestWorktreeDefaultPreparesSourceAndWorkerOnly(t *testing.T) {
	home, path, log := worktreeFixture(t, matchingTunnelScript(0, 0))
	makeWorktreeMirror(t, home, "lovable.daphen-every-55")
	messages := make(chan map[string]any, 1)
	listener, done := worktreeSocket(t, home, `{"sessions":[]}`, messages)
	defer listener.Close()
	result := runWorktreeBinary(t, home, path, "EVERY-55")
	if result.err != nil || !strings.Contains(result.stdout, "app startup not requested") || !strings.Contains(result.stdout, "source mirror ready") {
		t.Fatalf("result=%+v", result)
	}
	<-done
	if message := <-messages; message["type"] != "spawn" || message["profile"] != "lovable-worker" {
		t.Fatalf("spawn=%v", message)
	}
	calls := readLog(t, log)
	if !strings.Contains(calls, "vm-sync|--prepare EVERY-55") {
		t.Fatalf("source-only preparation missing: %s", calls)
	}
	for _, forbidden := range []string{"tmux", "devenv wt", "process-compose-wt-", "systemd-run|", "systemctl|", "direnv", "pnpm install"} {
		if strings.Contains(calls, forbidden) {
			t.Fatalf("default startup ran %s: %s", forbidden, calls)
		}
	}
}

func TestWorktreeRunsPortedFlowAndSpawnsAgent(t *testing.T) {
	web, api := freePort(t), freePort(t)
	script := fmt.Sprintf(`
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*"process-compose-wt-"*) printf '/remote/process-compose-wt-%d.yaml\n---VMCTL-CONFIG---\n    - WEB_PORT=%d\n    - VITE_GO_API_BASE_URL=http://127.0.0.1:%d\n' ;;
  "ssh|"*" rev-parse HEAD"*) echo 'Warning: Permanently added fake' >&2; echo 0123456789abcdef0123456789abcdef01234567 ;;
  "ssh|"*"playwright"*) exit 1 ;;
  "ssh|"*) echo 'Warning: Permanently added fake'; echo '  remote ok' ;;
  "git|"*" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "vm-sync|"*) echo sync-complete ;;
  "systemctl|"*"LoadState"*) echo not-found ;;
esac
`, web, web, api)
	home, path, log := worktreeFixture(t, script)
	mirror := filepath.Join(home, "work", "lovable.daphen-every-44")
	if err := os.MkdirAll(mirror, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mirror, "package.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mirror, ".git"), []byte("gitdir: fake"), 0o644); err != nil {
		t.Fatal(err)
	}
	messages := make(chan map[string]any, 1)
	listener, done := worktreeSocket(t, home, `{"sessions":[]}`, messages)
	defer listener.Close()

	stopReady := make(chan func(), 1)
	go func() {
		time.Sleep(250 * time.Millisecond)
		_, _, stopHTTP := worktreeHTTPAt(t, web, api, http.StatusOK, http.StatusOK)
		stopReady <- stopHTTP
	}()
	result := runWorktreeBinaryArgs(t, home, path, "--app", "EvErY-44")
	stop := <-stopReady
	defer stop()
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
		"boot devenv wt in tmux session wt-every-44", "  sync-complete",
		"source mirror ready", "✗ playwright override failed (non-fatal)",
		"spawned 'every-44' with the plan seed", "agent ready: select 'every-44' in the rail",
		fmt.Sprintf("HTTP ready — testable URL: http://localhost:%d/", web),
	} {
		if !strings.Contains(result.stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, result.stdout)
		}
	}
	if strings.Contains(result.stdout, "Warning: Permanently") {
		t.Errorf("host warning leaked: %s", result.stdout)
	}
	calls := readLog(t, log)
	var tunnelCall string
	for _, call := range strings.Split(calls, "\n") {
		if strings.HasPrefix(call, "systemd-run|") {
			tunnelCall = call
		}
	}
	if !strings.Contains(tunnelCall, "/run/current-system/sw/bin/ssh -N -o AddressFamily=any -o BatchMode=yes -o ConnectTimeout=25") {
		t.Errorf("persistent tunnel missing address-family override or ConnectTimeout:\n%s", tunnelCall)
	}
	inOrder(t, calls, "ssh|-o StrictHostKeyChecking=no", "git -C '/home/tester/src/lovable' worktree add", "ssh|-o StrictHostKeyChecking=no", "tmux new-session",
		"vm-sync|--prepare EvErY-44", "git|-C "+mirror+" rev-parse HEAD")
	for _, want := range []string{"show-ref --verify --quiet 'refs/heads/daphen/every-44'", "worktree add '/home/tester/src/lovable-every-44' 'daphen/every-44'", "worktree add -b 'daphen/every-44' '/home/tester/src/lovable-every-44' origin/main", "nix develop ./nix-config --impure -c ./bin/devenv wt --no-meticulous", `"@playwright/mcp@0.0.80"`, `"--executable-path", "/nix/store/4zn3d0v19mhpw5k3mn5l684v4y79na7k-chromium-143.0.7499.169/bin/chromium"`, `"env": { "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1" }`, "grep -qx '.pi/'", fmt.Sprintf("-L 127.0.0.1:%d:127.0.0.1:%d", web, web), fmt.Sprintf("-L 127.0.0.1:%d:127.0.0.1:%d", api, api)} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls missing %q:\n%s", want, calls)
		}
	}
	for _, stale := range []string{"WORKTRUNK_WORKTREE_PATH", "wt -C '/home/tester/src/lovable'", "@playwright/mcp@latest", "PLAYWRIGHT_BROWSERS_PATH", "6n74mm97b8f8gfra77hiz9q4ffiianpy-playwright-browsers"} {
		if strings.Contains(calls, stale) {
			t.Errorf("calls contain stale Playwright value %q:\n%s", stale, calls)
		}
	}
}

func TestWorktreePassesCABundleToNewTmuxSession(t *testing.T) {
	for _, supplied := range []string{"", "/trusted/custom CA's.pem"} {
		t.Run(supplied, func(t *testing.T) {
			t.Setenv("NODE_EXTRA_CA_CERTS", supplied)
			home, path, _ := worktreeFixture(t, `
case "$*" in
  *"tmux new-session"*) eval "script=\${$#}"; /bin/sh -c "$script"; exit 23 ;;
esac
`)
			tmux := `#!/bin/sh
case "$1" in
  has-session) exit 1 ;;
  new-session)
    ca=not-forwarded
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -e ]; then shift; case "$1" in NODE_EXTRA_CA_CERTS=*) ca=${1#*=} ;; esac; fi
      shift
    done
    printf '%s' "$ca" > "$HOME/launch-ca"
    exit 23 ;;
esac
`
			if err := os.WriteFile(filepath.Join(path, "tmux"), []byte(tmux), 0o755); err != nil {
				t.Fatal(err)
			}
			listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, nil)
			defer listener.Close()
			result := runWorktreeBinaryArgs(t, home, path, "--app", "EVERY-44")
			if result.err == nil || !strings.Contains(result.stderr, "remote dev startup failed") {
				t.Fatalf("fixture must stop after capturing tmux startup: %+v", result)
			}
			got, err := os.ReadFile(filepath.Join(home, "launch-ca"))
			want := supplied
			if want == "" {
				want = "/etc/ssl/certs/ca-certificates.crt"
			}
			if err != nil || string(got) != want {
				t.Fatalf("tmux CA=%q, want %q: %v", got, want, err)
			}
		})
	}
}

func TestWorktreeSurfacesCheckoutAndBootFailures(t *testing.T) {
	for _, tc := range []struct {
		name, match, diagnostic, want, forbidden string
	}{
		{"checkout", " worktree add", "worktree disk full", "worktree disk full", "tmux new-session"},
		{"checkout empty output", "show-ref --verify", "", "exit status 7", "tmux new-session"},
		{"boot", "tmux new-session", "tmux rejected cwd", "tmux rejected cwd", "vm-sync|"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*"` + tc.match + `"*) echo '` + tc.diagnostic + `' >&2; exit 7 ;;
esac
`
			home, path, log := worktreeFixture(t, script)
			listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, nil)
			defer listener.Close()
			result := runWorktreeBinaryArgs(t, home, path, "--app", "EVERY-54")
			calls := readLog(t, log)
			if result.err == nil || !strings.Contains(result.stderr, tc.want) || strings.Contains(calls, tc.forbidden) {
				t.Fatalf("result=%+v calls=%s", result, calls)
			}
		})
	}
}

func TestWorktreeSetupHandlesNewBranchExistingBranchAndCheckout(t *testing.T) {
	home, path, log := worktreeFixture(t, `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
[ "$name" = vm-sync ] && exit 9
exit 0
`)
	listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, nil)
	defer listener.Close()
	_ = runWorktreeBinary(t, home, path, "EVERY-55")
	calls := readLog(t, log)
	start, end := strings.Index(calls, "if [ -d '"), strings.Index(calls, "\nvm-sync|")
	if start < 0 || end < start {
		t.Fatalf("setup shell not captured:\n%s", calls)
	}
	remote, gitLog := filepath.Join(home, "remote", "lovable"), filepath.Join(home, "git.log")
	setup := strings.ReplaceAll(calls[start:end], "/home/tester/src/lovable", remote)
	git := `#!/bin/sh
printf '%s\n' "$*" >> "$GIT_LOG"
case "$*" in
  *"show-ref"*) [ "${BRANCH_EXISTS:-}" = yes ] ;;
  *"worktree add"*) mkdir -p "$REMOTE_WT"; [ "${FAIL_ADD:-}" != true ] || { echo partial-checkout-failure >&2; exit 7; } ;;
esac
`
	_ = os.WriteFile(filepath.Join(path, "git"), []byte(git), 0o755)
	for _, tc := range []struct {
		name, branch, want string
		checkout, fail     bool
	}{
		{"existing checkout", "", "", true, false},
		{"new branch", "", "worktree add -b daphen/every-55 ", false, false},
		{"existing branch", "yes", "worktree add " + remote + "-every-55 daphen/every-55", false, false},
		{"partial checkout failure", "", "", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_ = os.RemoveAll(remote + "-every-55")
			if tc.checkout {
				_ = os.MkdirAll(remote+"-every-55", 0o755)
			}
			cmd := exec.Command("/bin/sh", "-c", setup)
			cmd.Env = append(os.Environ(), "PATH="+path+":"+os.Getenv("PATH"), "GIT_LOG="+gitLog, "REMOTE_WT="+remote+"-every-55", "BRANCH_EXISTS="+tc.branch, fmt.Sprintf("FAIL_ADD=%t", tc.fail))
			output, err := cmd.CombinedOutput()
			if tc.fail {
				if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 7 || !strings.Contains(string(output), "partial-checkout-failure") || !pathExists(remote+"-every-55") {
					t.Fatalf("partial checkout failure lost: err=%v output=%s", err, output)
				}
				return
			}
			if err != nil {
				t.Fatalf("setup failed: %v: %s", err, output)
			}
			got, _ := os.ReadFile(gitLog)
			if tc.want == "" && len(got) != 0 || tc.want != "" && !strings.Contains(string(got), tc.want) {
				t.Fatalf("git calls=%q want %q", got, tc.want)
			}
		})
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
			roster := `{"sessions":[{"name":"every-45","profile":"` + tc.profile + `","cwd":"/home/tester/src/lovable-every-45"}]}`
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

func TestWorktreeRepeatedStartUsesRegisteredCwdAndMatchingTunnel(t *testing.T) {
	web, api, stop := worktreeHTTPAt(t, 0, 0, http.StatusOK, http.StatusOK)
	defer stop()
	remote := "/home/tester/src/lovable.tester-every-46-feature"
	script := matchingTunnelScript(web, api) + fmt.Sprintf(`
case "${0##*/}|$*" in
  "ssh|"*"process-compose-wt-"*) printf '/remote/config.yaml\n---VMCTL-CONFIG---\n- WEB_PORT=%d\n- VITE_GO_API_BASE_URL=http://127.0.0.1:%d\n' ;;
  "ssh|"*" rev-parse HEAD"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "vm-sync|"*) exit 0 ;;
esac
`, web, api)
	home, path, log := worktreeFixture(t, script)
	makeWorktreeMirror(t, home, filepath.Base(remote))
	messages := make(chan map[string]any, 3)
	roster := fmt.Sprintf(`{"sessions":[{"name":"every-46","profile":"lovable-worker","cwd":%q}]}`, remote)
	listener, done := worktreeAgentSocket(t, home, roster, `{"type":"text","text":"history"}`, messages)
	defer listener.Close()
	result := runWorktreeBinaryArgs(t, home, path, "--app", "EVERY-46")
	<-done
	if result.err != nil || !strings.Contains(result.stdout, "registered checkout: "+remote) || !strings.Contains(result.stdout, "HTTP ready") {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	if strings.Contains(calls, "git worktree add") || strings.Contains(calls, "systemd-run|") || !strings.Contains(calls, "vm-sync|--prepare --remote-cwd "+remote+" EVERY-46") {
		t.Fatalf("wrong repeated-start flow:\n%s", calls)
	}
}

func TestWorktreeRefusesRegisteredWrongCwdBeforeRemoteCommands(t *testing.T) {
	home, path, log := worktreeFixture(t, `echo "${0##*/}|$*" >> "$VMCTL_LOG"`)
	roster := `{"sessions":[{"name":"every-47","profile":"lovable-worker","cwd":"/home/tester/src/lovable-every-99"}]}`
	listener, _ := worktreeSocket(t, home, roster, nil)
	defer listener.Close()
	result := runWorktreeBinary(t, home, path, "EVERY-47")
	if result.err == nil || !strings.Contains(result.stderr, "registered cwd") || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func TestWorktreeMirrorHeadIgnoresSSHWarningAndPreservesSSHFailure(t *testing.T) {
	for _, tc := range []struct {
		name, remoteResult, want string
	}{
		{"warning with matching head", "echo 'Warning: Permanently added fake' >&2; echo 0123456789abcdef0123456789abcdef01234567", "source mirror ready"},
		{"failure diagnostic", "echo 'remote git diagnostic' >&2; exit 7", "remote git diagnostic"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*" rev-parse HEAD"*) ` + tc.remoteResult + ` ;;
  "git|"*" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "vm-sync|"*) exit 0 ;;
esac
`
			home, path, log := worktreeFixture(t, script)
			makeWorktreeMirror(t, home, "lovable.daphen-every-53")
			listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, make(chan map[string]any, 1))
			defer listener.Close()
			result := runWorktreeBinary(t, home, path, "EVERY-53")
			if !strings.Contains(result.stdout, tc.want) {
				t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
			}
			if tc.name == "warning with matching head" && strings.Contains(result.stdout, "Warning: Permanently") {
				t.Fatalf("SSH warning contaminated the parsed head: %s", result.stdout)
			}
			if tc.name == "failure diagnostic" && strings.Contains(readLog(t, log), "process-compose-wt-") {
				t.Fatalf("HTTP readiness ran after mirror verification failure:\n%s", readLog(t, log))
			}
		})
	}
}

func TestWorktreeExistingGitDirWithSyncFailureIsNotMirrorReady(t *testing.T) {
	script := `
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "vm-sync|"*) echo install-failed; exit 9 ;;
esac
`
	home, path, log := worktreeFixture(t, script)
	makeWorktreeMirror(t, home, "lovable.daphen-every-52")
	messages := make(chan map[string]any, 1)
	listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, messages)
	defer listener.Close()
	result := runWorktreeBinary(t, home, path, "EVERY-52")
	if result.err == nil || !strings.Contains(result.stdout, "install-failed") || !strings.Contains(result.stdout, "source mirror not ready") || !strings.Contains(result.stdout, "new agent was not spawned") {
		t.Fatalf("result=%+v", result)
	}
	if strings.Contains(readLog(t, log), "process-compose-wt-") {
		t.Fatalf("HTTP readiness ran after sync failure:\n%s", readLog(t, log))
	}
	select {
	case message := <-messages:
		t.Fatalf("new worker command sent after mirror failure: %#v", message)
	default:
	}
}

func TestWorktreeRejectsScriptAsset500AfterEarlierAnchor(t *testing.T) {
	web, api, stop := worktreeHTTPAt(t, 0, 0, http.StatusOK, http.StatusInternalServerError)
	defer stop()
	script := strings.ReplaceAll(matchingTunnelScript(web, api), " tester@test-host", " -L 127.0.0.1:8001:127.0.0.1:8001 tester@test-host") + fmt.Sprintf(`
case "${0##*/}|$*" in
  "ssh|"*"process-compose-wt-"*) printf '/remote/config.yaml\n---VMCTL-CONFIG---\n- WEB_PORT=%d\n- VITE_GO_API_BASE_URL=http://127.0.0.1:%d\n' ;;
esac
`, web, api)
	home, path, _ := worktreeFixture(t, script)
	makeWorktreeMirror(t, home, "lovable.daphen-every-48")
	listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, make(chan map[string]any, 1))
	defer listener.Close()
	result := runWorktreeBinaryArgs(t, home, path, "--script-tag", "EVERY-48")
	if result.err == nil || !strings.Contains(result.stdout, fmt.Sprintf("client asset http://localhost:%d/src/main.tsx returned HTTP 500", web)) || strings.Contains(result.stdout, "HTTP ready —") {
		t.Fatalf("result=%+v", result)
	}
	if !strings.Contains(result.stdout, "agent context was preserved") {
		t.Fatalf("missing preserved context: %s", result.stdout)
	}
}

func TestWorktreeRejectsOccupiedPortWithoutOwnedTunnel(t *testing.T) {
	web, api, stop := worktreeHTTPAt(t, 0, 0, http.StatusOK, http.StatusOK)
	defer stop()
	script := fmt.Sprintf(`
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*"process-compose-wt-"*) printf '/remote/config.yaml\n---VMCTL-CONFIG---\n- WEB_PORT=%d\n- VITE_GO_API_BASE_URL=http://127.0.0.1:%d\n' ;;
  "ssh|"*" rev-parse HEAD"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "systemctl|"*"LoadState"*) echo not-found ;;
  "ss|"*) echo 'users:(("other",pid=77))' ;;
esac
`, web, api)
	home, path, log := worktreeFixture(t, script)
	makeWorktreeMirror(t, home, "lovable.daphen-every-49")
	listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, make(chan map[string]any, 1))
	defer listener.Close()
	result := runWorktreeBinaryArgs(t, home, path, "--app", "EVERY-49")
	if result.err == nil || !strings.Contains(result.stdout, fmt.Sprintf("local loopback port %d is already in use", web)) || strings.Contains(readLog(t, log), "systemd-run|") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestWorktreeTunnelTeardownUsesOwnedUnitOnly(t *testing.T) {
	home, path, log := worktreeFixture(t, `echo "${0##*/}|$*" >> "$VMCTL_LOG"`)
	result := runWorktreeBinaryArgs(t, home, path, "--teardown", "EVERY-51")
	if result.err != nil || !strings.Contains(result.stdout, "agent, mirror, and remote dev slice were left running") || !strings.Contains(readLog(t, log), "systemctl|--user stop every-51-dev-tunnel.service") {
		t.Fatalf("result=%+v calls=%s", result, readLog(t, log))
	}
}

func TestReapUsesNativeGitAndArchivesEvidenceWithoutDeletingBranches(t *testing.T) {
	t.Setenv("COCKPIT_AGENT_PROFILE", "lovable-orchestrator")
	f := newRetirementFixture(t, "secret/\n")
	os.MkdirAll(filepath.Join(f.remoteWT, "secret"), 0o700)
	os.WriteFile(filepath.Join(f.remoteWT, "secret", "evidence.md"), []byte("durable evidence\n"), 0o600)
	shared := filepath.Join(f.home, "shared-cache")
	os.MkdirAll(shared, 0o700)
	os.WriteFile(filepath.Join(shared, "keep"), []byte("shared\n"), 0o600)
	os.Symlink(shared, filepath.Join(f.remoteWT, "node_modules", "shared"))
	result := f.run(t, "--reap")
	if result.err != nil {
		t.Fatalf("result=%+v\ncalls=%s", result, readLog(t, f.log))
	}
	if pathExists(f.remoteWT) || pathExists(f.mirror) {
		t.Fatalf("remote=%t mirror=%t credential=%t", pathExists(f.remoteWT), pathExists(f.mirror), pathExists(filepath.Join(f.mirror, ".pi/mcp.json")))
	}
	if got := strings.TrimSpace(runGit(t, f.remoteRepo, "rev-parse", "daphen/every-77")); got != f.head {
		t.Fatalf("branch moved: %s != %s", got, f.head)
	}
	archives, _ := filepath.Glob(filepath.Join(f.home, ".local/state/cockpit/retired/*/evidence.tar.gz"))
	if len(archives) != 2 {
		t.Fatalf("archives: %v", archives)
	}
	found := false
	for _, archive := range archives {
		info, _ := os.Stat(archive)
		if info.Mode().Perm()&0o077 != 0 {
			t.Fatal("archive permissions expose credentials")
		}
		data, err := exec.Command("tar", "-xOf", archive, ".pi/mcp.json").Output()
		if err != nil || string(data) != "protected\n" {
			t.Fatalf("credentials not preserved: %s %v", data, err)
		}
		listing, _ := exec.Command("tar", "-tf", archive).Output()
		if strings.Contains(string(listing), "node_modules/pkg/cache") || strings.Contains(string(listing), ".devenv/state/go/bin/cache") {
			t.Fatal("cache was archived instead of reclaimed")
		}
		found = found || strings.Contains(string(listing), "secret/evidence.md")
	}
	if !found || string(mustRead(t, filepath.Join(shared, "keep"))) != "shared\n" {
		t.Fatal("evidence/shared cache not preserved")
	}
	calls := readLog(t, f.log)
	for _, forbidden := range []string{"worktree remove --force", "rm -rf"} {
		if strings.Contains(calls, forbidden) {
			t.Fatalf("retirement used forbidden %q:\n%s", forbidden, calls)
		}
	}
	if !strings.Contains(result.stdout, "confirmed VM worktree removed with native Git") || !strings.Contains(result.stdout, "REAP complete") {
		t.Fatalf("completion was not visible: %s", result.stdout)
	}

	_ = os.Remove(filepath.Join(f.home, "run/agentd-work.sock"))
	rerun := f.run(t, "--reap")
	if rerun.err != nil || !strings.Contains(rerun.stdout, "already absent") {
		t.Fatalf("rerun=%+v", rerun)
	}
}

func TestNativeOrchestratorReapsFromOutsideTarget(t *testing.T) {
	f := newRetirementFixture(t, "")
	t.Setenv("COCKPIT_AGENT_PROFILE", "lovable-orchestrator")
	repo := filepath.Join(f.home, "src/lovable")
	os.MkdirAll(filepath.Dir(repo), 0o755)
	runGit(t, f.home, "clone", f.remoteRepo, repo)
	wt := repo + "-every-77"
	runGit(t, repo, "worktree", "add", "-b", "daphen/every-77", wt, "origin/daphen/every-77")
	listener, done := worktreeSocket(t, f.home, `{"sessions":[]}`, nil)
	defer closeRetirementRoster(listener, done)
	result := runWorktreeBinaryAt(t, f.home, f.path, repo, "--native", "--reap", "EVERY-77")
	if result.err != nil || pathExists(wt) || !pathExists(f.mirror) || !strings.Contains(result.stdout, "REAP complete") {
		t.Fatalf("result=%+v", result)
	}
	if strings.TrimSpace(runGit(t, repo, "rev-parse", "daphen/every-77")) != f.head {
		t.Fatal("ticket branch was not preserved")
	}
	for _, forbidden := range []string{"ssh|", "mutagen|", "systemctl|"} {
		if strings.Contains(readLog(t, f.log), forbidden) {
			t.Fatal(readLog(t, f.log))
		}
	}
}

func TestNativeVMResumesRetainedCheckoutWithoutDesktopTools(t *testing.T) {
	f := newRetirementFixture(t, "")
	repo := filepath.Join(f.home, "src/lovable")
	os.MkdirAll(filepath.Dir(repo), 0o755)
	runGit(t, f.home, "clone", f.remoteRepo, repo)
	wt := repo + "-every-77"
	runGit(t, repo, "worktree", "add", "-b", "daphen/every-77", wt, "origin/daphen/every-77")
	head := strings.TrimSpace(runGit(t, wt, "rev-parse", "HEAD"))
	for _, name := range []string{"ssh", "mutagen", "wt", "vm-sync", "systemd-run"} {
		os.Remove(filepath.Join(f.path, name))
	}
	os.Remove(filepath.Join(f.home, ".local/bin/vm-sync"))
	messages := make(chan map[string]any, 2)
	listener, done := worktreeSocket(t, f.home, `{"sessions":[]}`, messages)
	result := runWorktreeBinaryArgs(t, f.home, f.path, "--native", "EVERY-77")
	closeRetirementRoster(listener, done)
	if result.err != nil {
		t.Fatalf("native launch=%+v", result)
	}
	if got := strings.TrimSpace(runGit(t, wt, "rev-parse", "HEAD")); got != head {
		t.Fatalf("retained HEAD changed: %s", got)
	}
	if dirty := strings.TrimSpace(runGit(t, wt, "status", "--porcelain")); dirty != "" {
		t.Fatal(dirty)
	}
	request := <-messages
	if request["type"] != "spawn" || request["cwd"] != wt || request["profile"] != "lovable-worker" {
		t.Fatal(request)
	}
	if strings.Contains(result.stdout, "source mirror") || pathExists(filepath.Join(f.home, "work/lovable.daphen-every-77/.devenv")) {
		t.Fatal(result.stdout)
	}
	if !strings.Contains(result.stdout, "orchestrator runs vm-wt --reap EVERY-77") || strings.Contains(result.stdout, "vm-wt --teardown") {
		t.Fatal("incorrect retirement guidance: " + result.stdout)
	}
}

func TestRetirementRejectsNonOrchestratorBeforeContactingDaemon(t *testing.T) {
	for _, key := range []string{"COCKPIT_AGENT_PROFILE", "HEIDR_AGENT_PROFILE"} {
		for _, profile := range []string{"lovable-worker", "lovable-watcher", "lovable-reviewer", "coding"} {
			t.Run(key+"/"+profile, func(t *testing.T) {
				f := newRetirementFixture(t, "")
				t.Setenv(key, profile)
				for _, action := range []string{"--off", "--reap"} {
					result := runWorktreeBinaryArgs(t, f.home, f.path, "--native", action, "EVERY-77")
					if result.err == nil || !strings.Contains(result.stderr, "orchestrator owns ticket shutdown") || readLog(t, f.log) != "" || !pathExists(f.remoteWT) {
						t.Fatalf("%s: result=%+v calls=%s", action, result, readLog(t, f.log))
					}
				}
			})
		}
	}
}

func TestRetirementRejectsOwnCwdBeforeContactingDaemon(t *testing.T) {
	for _, native := range []bool{false, true} {
		for _, location := range []string{"root", "nested", "symlink"} {
			t.Run(fmt.Sprintf("native=%t/%s", native, location), func(t *testing.T) {
				f := newRetirementFixture(t, "")
				t.Setenv("COCKPIT_AGENT_PROFILE", "lovable-orchestrator")
				cwd := f.mirror
				if native {
					cwd = filepath.Join(f.home, "src/lovable-every-77")
				}
				if location == "nested" {
					cwd = filepath.Join(cwd, "nested")
				}
				if err := os.MkdirAll(cwd, 0o755); err != nil {
					t.Fatal(err)
				}
				if location == "symlink" {
					link := filepath.Join(f.home, "alias")
					if err := os.Symlink(cwd, link); err != nil {
						t.Fatal(err)
					}
					cwd = link
				}
				for _, action := range []string{"--off", "--reap"} {
					args := []string{action, "EVERY-77"}
					if native {
						args = append([]string{"--native"}, args...)
					}
					result := runWorktreeBinaryAt(t, f.home, f.path, cwd, args...)
					if result.err == nil || !strings.Contains(result.stderr, "run from outside") || readLog(t, f.log) != "" || !pathExists(cwd) {
						t.Fatalf("%s: result=%+v calls=%s", action, result, readLog(t, f.log))
					}
				}
			})
		}
	}
}

func TestTurnOffRetainsWorktreesAndCaches(t *testing.T) {
	f := newRetirementFixture(t, "")
	result := f.run(t, "--off")
	if result.err != nil || !pathExists(f.remoteWT) || !pathExists(f.mirror) || !pathExists(filepath.Join(f.remoteWT, "node_modules/pkg/cache")) {
		t.Fatalf("off=%+v", result)
	}
	if !strings.Contains(readLog(t, f.log), "runtime|") || strings.Contains(readLog(t, f.log), "worktree remove") {
		t.Fatal(readLog(t, f.log))
	}
}

func TestReapStopsAtRuntimeFailure(t *testing.T) {
	f := newRetirementFixture(t, "")
	t.Setenv("RUNTIME_FAIL", "7")
	result := f.run(t, "--reap")
	if result.err == nil || !pathExists(f.remoteWT) || !pathExists(f.mirror) || !strings.Contains(result.stderr, "shutdown not confirmed") {
		t.Fatalf("result=%+v", result)
	}
}

func TestTurnOffConfirmsNamedAgentStop(t *testing.T) {
	f := newRetirementFixture(t, "")
	listener, err := net.Listen("unix", filepath.Join(f.home, "run/agentd-work.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan bool, 1)
	go func() {
		for i := 0; i < 2; i++ {
			conn, err := listener.Accept()
			if err != nil {
				done <- false
				return
			}
			fmt.Fprintln(conn, `{"type":"roster","sessions":[{"name":"every-77","cwd":"/home/tester/src/lovable-every-77","profile":"lovable-worker"}]}`)
			if i == 1 {
				var command map[string]string
				if json.NewDecoder(conn).Decode(&command) != nil || command["type"] != "stop" || command["session"] != "every-77" {
					conn.Close()
					done <- false
					return
				}
				fmt.Fprintln(conn, `{"type":"roster","sessions":[]}`)
			}
			conn.Close()
		}
		done <- true
	}()
	result := runWorktreeBinaryArgs(t, f.home, f.path, "--off", "EVERY-77")
	if result.err != nil || !<-done || !strings.Contains(result.stdout, "session stopped") {
		t.Fatalf("result=%+v", result)
	}
}

func TestRetireWorktreePreservesDetachedHead(t *testing.T) {
	f := newRetirementFixture(t, "")
	runGit(t, f.remoteWT, "checkout", "--detach", f.head)
	result := f.run(t, "--reap")
	keep := "retired/every-77-" + f.head[:12]
	if result.err != nil || strings.TrimSpace(runGit(t, f.remoteRepo, "rev-parse", keep)) != f.head {
		t.Fatalf("result=%+v keep=%s", result, keep)
	}
}

func TestRetireWorktreeBlocksOwnersAndValuableData(t *testing.T) {
	t.Run("roster owner", func(t *testing.T) {
		f := newRetirementFixture(t, "")
		roster := `{"sessions":[{"name":"other-owner","profile":"lovable-worker","cwd":"/home/tester/src/lovable-every-77"}]}`
		listener, done := worktreeSocket(t, f.home, roster, nil)
		result := runWorktreeBinaryArgs(t, f.home, f.path, "--reap", "EVERY-77")
		closeRetirementRoster(listener, done)
		if result.err == nil || !strings.Contains(result.stderr, "still owns") || !pathExists(f.remoteWT) || readLog(t, f.log) != "" {
			t.Fatalf("result=%+v calls=%s", result, readLog(t, f.log))
		}
	})
	for _, tc := range []struct{ name, setup, want string }{
		{"tracked", "tracked", "tracked changes"},
		{"untracked", "untracked", "untracked data"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newRetirementFixture(t, "secret/\nbazel-*/\n")
			switch tc.setup {
			case "tracked":
				os.WriteFile(filepath.Join(f.remoteWT, "README.md"), []byte("changed\n"), 0o644)
			case "untracked":
				os.WriteFile(filepath.Join(f.remoteWT, "notes.md"), []byte("valuable\n"), 0o600)

			}
			result := f.run(t, "--reap")
			if result.err == nil || !strings.Contains(result.stdout+result.stderr, tc.want) || !pathExists(f.remoteWT) {
				t.Fatalf("result=%+v", result)
			}
		})
	}
}

func TestRetireWorktreeBlocksWrongSyncAndActiveCwd(t *testing.T) {
	t.Run("wrong tunnel endpoint", func(t *testing.T) {
		f := newRetirementFixture(t, "")
		t.Setenv("TUNNEL_EXEC", "ssh -N -L 127.0.0.1:42:127.0.0.1:42 other@other-host")
		result := f.run(t, "--reap")
		if result.err == nil || !strings.Contains(result.stderr, "not the expected VM loopback tunnel") || !pathExists(f.remoteWT) {
			t.Fatalf("result=%+v", result)
		}
	})
	t.Run("wrong sync endpoint", func(t *testing.T) {
		f := newRetirementFixture(t, "")
		t.Setenv("MUTAGEN_JSON", `[{"name":"vmwt-every-77","alpha":{"protocol":"ssh","user":"other","host":"test-host","path":"/home/tester/src/lovable-every-77"},"beta":{"protocol":"local","path":"`+f.mirror+`"}}]`)
		result := f.run(t, "--reap")
		if result.err == nil || !strings.Contains(result.stderr, "exact expected endpoints") || !pathExists(f.remoteWT) {
			t.Fatalf("result=%+v", result)
		}
	})
	t.Run("active cwd", func(t *testing.T) {
		f := newRetirementFixture(t, "")
		proc := exec.Command("/bin/sh", "-c", "cd \"$1\" && exec sleep 30", "sh", f.remoteWT)
		if err := proc.Start(); err != nil {
			t.Fatal(err)
		}
		defer func() { _ = proc.Process.Kill(); _, _ = proc.Process.Wait() }()
		result := f.run(t, "--reap")
		if result.err == nil || !strings.Contains(result.stdout+result.stderr, "active CWD or file") || !pathExists(f.remoteWT) {
			t.Fatalf("result=%+v", result)
		}
	})
}

type retirementFixture struct {
	home, path, log, remoteRepo, remoteWT, mirror, head string
}

func (f retirementFixture) run(t *testing.T, action string) result {
	t.Helper()
	listener, done := worktreeSocket(t, f.home, `{"sessions":[]}`, nil)
	defer closeRetirementRoster(listener, done)
	return runWorktreeBinaryArgs(t, f.home, f.path, action, "EVERY-77")
}

func closeRetirementRoster(listener net.Listener, done <-chan struct{}) {
	_ = listener.Close()
	<-done
}

func newRetirementFixture(t *testing.T, extraIgnore string) retirementFixture {
	t.Helper()
	home, path, log := worktreeFixture(t, "")
	gitPath, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	_ = os.Remove(filepath.Join(path, "git"))
	if err := os.Symlink(gitPath, filepath.Join(path, "git")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sed", "grep", "sha256sum", "cut", "readlink", "sh", "tar", "mkdir", "mktemp", "head", "awk", "wt", "find", "cat", "gzip"} {
		command, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(command, filepath.Join(path, name)); err != nil {
			t.Fatal(err)
		}
	}
	remoteRepo := filepath.Join(home, "remote", "lovable")
	remoteWT := filepath.Join(home, "remote", "lovable-every-77")
	if err := os.MkdirAll(remoteRepo, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, remoteRepo, "init", "-b", "main")
	runGit(t, remoteRepo, "config", "user.email", "test@example.com")
	runGit(t, remoteRepo, "config", "user.name", "Test")
	ignore := ".pi/\n.mcp.json\nnode_modules/\n.devenv/\n.wrangler/\n" + extraIgnore
	os.WriteFile(filepath.Join(remoteRepo, ".gitignore"), []byte(ignore), 0o644)
	os.WriteFile(filepath.Join(remoteRepo, "README.md"), []byte("fixture\n"), 0o644)
	runGit(t, remoteRepo, "add", ".")
	runGit(t, remoteRepo, "commit", "-m", "fixture")
	runGit(t, remoteRepo, "worktree", "add", "-b", "daphen/every-77", remoteWT, "main")
	head := strings.TrimSpace(runGit(t, remoteWT, "rev-parse", "HEAD"))
	localRepo := filepath.Join(home, "work", "lovable")
	if err := os.MkdirAll(filepath.Dir(localRepo), 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, home, "clone", remoteRepo, localRepo)
	mirror := filepath.Join(home, "work", "lovable.daphen-every-77")
	runGit(t, localRepo, "worktree", "add", "-b", "daphen/every-77", mirror, "origin/daphen/every-77")
	for _, root := range []string{remoteWT, mirror} {
		os.MkdirAll(filepath.Join(root, ".pi"), 0o700)
		os.WriteFile(filepath.Join(root, ".pi/mcp.json"), []byte("protected\n"), 0o600)
		os.WriteFile(filepath.Join(root, ".mcp.json"), []byte("root-protected\n"), 0o600)
	}
	os.MkdirAll(filepath.Join(remoteWT, "node_modules/pkg"), 0o755)
	os.WriteFile(filepath.Join(remoteWT, "node_modules/pkg/cache"), []byte("generated\n"), 0o644)
	os.MkdirAll(filepath.Join(remoteWT, ".devenv/state"), 0o755)
	os.WriteFile(filepath.Join(remoteWT, ".devenv/state/process-compose-wt-fixture.yaml"), []byte("generated\n"), 0o644)
	os.MkdirAll(filepath.Join(remoteWT, ".devenv/state/go/bin"), 0o755)
	os.WriteFile(filepath.Join(remoteWT, ".devenv/state/go/bin/cache"), []byte("compiled cache\n"), 0o644)
	ssh := `#!/bin/sh
printf 'ssh|%s\n' "$*" >> "$VMCTL_LOG"
eval "script=\${$#}"
script=$(printf '%s' "$script" | sed "s|/home/tester/src/lovable-every-77|$REMOTE_WT|g; s|/home/tester/src/lovable|$REMOTE_REPO|g")
exec /bin/sh -c "$script"
`
	mutagen := `#!/bin/sh
printf 'mutagen|%s\n' "$*" >> "$VMCTL_LOG"
case "$*" in "sync list "*) printf '%s\n' "${MUTAGEN_JSON-[]}";; esac
`
	systemctl := `#!/bin/sh
printf 'systemctl|%s\n' "$*" >> "$VMCTL_LOG"
case "$*" in *"LoadState"*) [ -n "${TUNNEL_EXEC-}" ] && echo loaded || echo not-found;; *"ExecStart"*) echo "${TUNNEL_EXEC-}";; *"is-active"*) exit 1;; esac
`
	for name, script := range map[string]string{"ssh": ssh, "mutagen": mutagen, "systemctl": systemctl} {
		if err := os.WriteFile(filepath.Join(path, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("REMOTE_REPO", remoteRepo)
	t.Setenv("REMOTE_WT", remoteWT)
	os.WriteFile(filepath.Join(home, ".local/bin/vm-slice-reaper"), []byte("#!/bin/sh\nprintf 'runtime|%s\\n' \"$*\" >> \"$VMCTL_LOG\"\nexit \"${RUNTIME_FAIL:-0}\"\n"), 0o755)
	return retirementFixture{home, path, log, remoteRepo, remoteWT, mirror, head}
}

func matchingTunnelScript(web, api int) string {
	return fmt.Sprintf(`
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name|$*" in
  "ssh|"*" rev-parse HEAD"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "git|"*" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "systemctl|"*"LoadState"*) echo loaded ;;
  "systemctl|"*"ExecStart"*) echo 'ssh -N -L 127.0.0.1:%d:127.0.0.1:%d -L 127.0.0.1:%d:127.0.0.1:%d tester@test-host' ;;
  "systemctl|--user is-active"*) exit 0 ;;
esac
`, web, web, api, api)
}

func matchingScriptTagTunnelScript(web, api int) string {
	return strings.Replace(matchingTunnelScript(web, api), " tester@test-host", " -L 127.0.0.1:8001:127.0.0.1:8001 tester@test-host", 1)
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	return port
}

func worktreeHTTPAt(t *testing.T, webPort, apiPort, webStatus, assetStatus int) (int, int, func()) {
	t.Helper()
	listen := func(port int, handler http.Handler) (net.Listener, *http.Server) {
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Error(err)
			return nil, nil
		}
		server := &http.Server{Handler: handler}
		go server.Serve(listener)
		return listener, server
	}
	webListener, webServer := listen(webPort, http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		status := assetStatus
		if request.URL.Path == "/" {
			status = webStatus
		}
		w.WriteHeader(status)
		if request.URL.Path == "/" {
			_, _ = w.Write([]byte(`<html><a href="/projects">projects</a><link rel="icon" href="/favicon.ico"><script type="module" src="/src/main.tsx"></script></html>`))
		}
	}))
	apiListener, apiServer := listen(apiPort, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"status":"ok"}`)) }))
	if webListener == nil || apiListener == nil {
		return 0, 0, func() {}
	}
	return webListener.Addr().(*net.TCPAddr).Port, apiListener.Addr().(*net.TCPAddr).Port, func() { _ = webServer.Close(); _ = apiServer.Close() }
}

func worktreeScriptTag(t *testing.T) func() {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:8001")
	if err != nil {
		response, getErr := http.Get("http://127.0.0.1:8001/lovable.js")
		if getErr != nil || response.StatusCode != http.StatusOK {
			t.Fatalf("ScriptTag test port unavailable: listen=%v get=%v", err, getErr)
		}
		_ = response.Body.Close()
		return func() {}
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("script")) })}
	go server.Serve(listener)
	return func() { _ = server.Close() }
}

func makeWorktreeMirror(t *testing.T, home, base string) {
	t.Helper()
	mirror := filepath.Join(home, "work", base)
	if err := os.MkdirAll(mirror, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mirror, ".git"), []byte("gitdir: fake"), 0o644); err != nil {
		t.Fatal(err)
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
	for _, name := range []string{"git", "ssh", "mutagen", "direnv", "nohup", "vm-sync", "systemctl", "systemd-run", "ss"} {
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
			if message["type"] == "spawn" {
				ack := map[string]any{"type": "roster", "sessions": []any{map[string]any{"name": message["session"], "cwd": message["cwd"], "profile": message["profile"]}}}
				data, _ := json.Marshal(ack)
				_, _ = conn.Write(append(data, '\n'))
				return
			}
			if message["type"] == "prompt" {
				return
			}
		}
	}()
	return listener, done
}

func runWorktreeBinary(t *testing.T, home, path, raw string) result {
	t.Helper()
	return runWorktreeBinaryArgs(t, home, path, raw)
}

func runWorktreeBinaryArgs(t *testing.T, home, path string, args ...string) result {
	t.Helper()
	return runWorktreeBinaryAt(t, home, path, "", args...)
}

func runWorktreeBinaryAt(t *testing.T, home, path, cwd string, args ...string) result {
	t.Helper()
	commandArgs := append([]string{"worktree"}, args...)
	if len(args) > 0 && args[0] == "--native" {
		commandArgs = append([]string{"--native", "worktree"}, args[1:]...)
	}
	cmd := exec.Command(binary, commandArgs...)
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+path, "VMCTL_LOG="+filepath.Join(home, "calls.log"),
		"XDG_RUNTIME_DIR="+filepath.Join(home, "run"), "COCKPIT_VM_USER=tester", "COCKPIT_VM_HOST=test-host")
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return result{stdout.String(), stderr.String(), err}
}
