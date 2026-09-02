package main

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCockpitArguments(t *testing.T) {
	home, path, log := cockpitFixture(t)
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"cockpit", "extra"}, "usage: vmctl cockpit [--restart]"},
		{[]string{"cockpit", "--bad"}, "usage: vmctl cockpit [--restart]"},
	} {
		result := runCockpitBinary(t, home, path, nil, tc.args...)
		if result.err == nil || !strings.Contains(result.stderr, tc.want) {
			t.Fatalf("args=%v result=%+v", tc.args, result)
		}
	}
	if calls := readLog(t, log); calls != "" {
		t.Fatalf("invalid arguments ran commands:\n%s", calls)
	}
}

func TestCockpitCurrentBundleAndHealthyTunnel(t *testing.T) {
	home, path, log := cockpitFixture(t)
	hash, err := bundleHash(filepath.Join(home, "nixos/dotfiles/ai"))
	if err != nil {
		t.Fatal(err)
	}
	listener := cockpitHealthySocket(t, filepath.Join(home, "run/agentd-work.sock"))
	defer listener.Close()
	result := runCockpitBinary(t, home, path, []string{
		"REMOTE_HASH_INITIAL=" + hash, "REMOTE_HASH_AFTER=" + hash,
		"PI_LOCAL=pi 0.83.0", "PI_REMOTE=pi 0.84.1", "WAS_RUNNING=yes", "DAEMON_MODE=already",
	}, "cockpit")
	if result.err != nil {
		t.Fatalf("failed: %v\nstdout=%s\nstderr=%s", result.err, result.stdout, result.stderr)
	}
	for _, want := range []string{
		"WARNING: pi version skew — local pi 0.83.0, VM pi 0.84.1",
		"role bundle current (" + hash + ")", "already running (pid 42, up 1:23)",
		"tunnel already healthy → " + filepath.Join(home, "run/agentd-work.sock"), "done — launch Cockpit",
	} {
		if !strings.Contains(result.stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, result.stdout)
		}
	}
	calls := readLog(t, log)
	if strings.Contains(calls, "rsync|") || strings.Contains(calls, "setsid|") {
		t.Fatalf("current/healthy path copied or tunneled:\n%s", calls)
	}
	inOrder(t, calls, "pi|--version", "ssh|-o StrictHostKeyChecking=no", "ssh|-o StrictHostKeyChecking=no", "python3 - instructions.md", "pgrep -x agentd", "fish|-c", "op|read", "export XDG_DATA_DIRS")
}

func TestCockpitDifferentBundleCopiesVerifiesAndMarksRunningDaemon(t *testing.T) {
	home, path, log := cockpitFixture(t)
	hash, _ := bundleHash(filepath.Join(home, "nixos/dotfiles/ai"))
	listener := cockpitHealthySocket(t, filepath.Join(home, "run/agentd-work.sock"))
	defer listener.Close()
	result := runCockpitBinary(t, home, path, []string{
		"REMOTE_HASH_INITIAL=old", "REMOTE_HASH_AFTER=" + hash, "WAS_RUNNING=yes", "DAEMON_MODE=already",
	}, "cockpit")
	if result.err != nil {
		t.Fatalf("failed: %v\n%s\n%s", result.err, result.stdout, result.stderr)
	}
	if !strings.Contains(result.stdout, "role bundle updated, agentd restart required ("+hash+")") {
		t.Fatalf("unexpected stdout:\n%s", result.stdout)
	}
	marker := filepath.Join(home, "run/cockpit-role-bundle-work.restart-required")
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("restart marker absent: %v", err)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "python3 - instructions.md", "pgrep -x agentd", "mkdir -p $HOME/.pi/agent/'", "rsync|-az --delete", "rsync|-az -e", ".pi/agent/AGENTS.md", "python3 - instructions.md", "fish|-c", "op|read", "export XDG_DATA_DIRS")
	if !strings.Contains(calls, "--delete") || strings.Contains(calls, "--delete -e") && !strings.Contains(calls, "roles/") {
		t.Fatalf("directory copy flags missing:\n%s", calls)
	}
}

func TestCockpitCopyFailureIsFatalAndLeavesMarker(t *testing.T) {
	home, path, log := cockpitFixture(t)
	result := runCockpitBinary(t, home, path, []string{"REMOTE_HASH_INITIAL=old", "FAIL_RSYNC=yes", "WAS_RUNNING=no"}, "cockpit")
	if result.err == nil || !strings.Contains(result.stdout, "sync failed, do not spawn ticket sessions") {
		t.Fatalf("result=%+v", result)
	}
	if _, err := os.Stat(filepath.Join(home, "run/cockpit-role-bundle-work.restart-required")); err != nil {
		t.Fatalf("restart marker absent: %v", err)
	}
	calls := readLog(t, log)
	if strings.Contains(calls, "fish|") || strings.Contains(calls, "export XDG_DATA_DIRS") {
		t.Fatalf("continued after copy failure:\n%s", calls)
	}
}

func TestCockpitVerificationFailureReportsHashes(t *testing.T) {
	home, path, _ := cockpitFixture(t)
	hash, _ := bundleHash(filepath.Join(home, "nixos/dotfiles/ai"))
	result := runCockpitBinary(t, home, path, []string{"REMOTE_HASH_INITIAL=old", "REMOTE_HASH_AFTER=still-old"}, "cockpit")
	if result.err == nil || !strings.Contains(result.stdout, "local "+hash+", remote still-old") {
		t.Fatalf("result=%+v", result)
	}
}

func TestCockpitDaemonRestartAndTunnelCreation(t *testing.T) {
	home, path, log := cockpitFixture(t)
	hash, _ := bundleHash(filepath.Join(home, "nixos/dotfiles/ai"))
	legacy := filepath.Join(home, "run/heidr-role-bundle-work.restart-required")
	if err := os.WriteFile(legacy, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(home, "run/agentd-work.sock")
	listener := make(chan net.Listener, 1)
	go func() {
		for i := 0; i < 200; i++ {
			calls, _ := os.ReadFile(log)
			if strings.Contains(string(calls), "setsid|ssh -N") {
				server, _ := net.Listen("unix", socket)
				listener <- server
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		listener <- nil
	}()
	result := runCockpitBinary(t, home, path, []string{
		"REMOTE_HASH_INITIAL=" + hash, "REMOTE_HASH_AFTER=" + hash, "WAS_RUNNING=yes", "DAEMON_MODE=restart",
		"OPENAI_VALUE=openai-secret", "SLACK_VALUE=slack-secret", "COCKPIT_VM_AGENTD_PORT=19001",
	}, "cockpit", "--restart")
	server := <-listener
	if server == nil {
		t.Fatal("fake tunnel did not start")
	}
	defer server.Close()
	if result.err != nil {
		t.Fatalf("failed: %v\nstdout=%s\nstderr=%s", result.err, result.stdout, result.stderr)
	}
	for _, want := range []string{"restart requested — stopping agentd", "listening ✓", "tunnel " + filepath.Join(home, "run/agentd-work.sock") + " → dev-heidr-2a39:19001", "  up ✓"} {
		if !strings.Contains(result.stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, result.stdout)
		}
	}
	if _, err := os.Stat(filepath.Join(home, "run/cockpit-role-bundle-work.restart-required")); !os.IsNotExist(err) {
		t.Fatalf("restart marker survived successful restart: %v", err)
	}
	calls := readLog(t, log)
	inOrder(t, calls, "fish|-c", "op|read", "ssh|-o StrictHostKeyChecking=no", "setsid|ssh -N")
	for _, want := range []string{"OPENAI_API_KEY='openai-secret'", "SLACK_MCP_CLIENT_SECRET='slack-secret'", "gnome-keyring-daemon", "DBUS_SESSION_BUS_ADDRESS", "COCKPIT_SLICE_REAP_HOOK", "--listen 127.0.0.1:19001", "-L " + filepath.Join(home, "run/agentd-work.sock") + ":127.0.0.1:19001"} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls missing %q:\n%s", want, calls)
		}
	}
}

func TestCockpitDaemonFailureIsFatal(t *testing.T) {
	home, path, _ := cockpitFixture(t)
	hash, _ := bundleHash(filepath.Join(home, "nixos/dotfiles/ai"))
	result := runCockpitBinary(t, home, path, []string{"REMOTE_HASH_INITIAL=" + hash, "DAEMON_MODE=fail"}, "cockpit")
	if result.err == nil || !strings.Contains(result.stdout, "agentd on dev-heidr-2a39") || strings.Contains(result.stdout, "tunnel ") {
		t.Fatalf("result=%+v", result)
	}
}

func TestCockpitTunnelFailureIsFatal(t *testing.T) {
	home, path, _ := cockpitFixture(t)
	hash, _ := bundleHash(filepath.Join(home, "nixos/dotfiles/ai"))
	result := runCockpitBinary(t, home, path, []string{"REMOTE_HASH_INITIAL=" + hash, "DAEMON_MODE=already", "TUNNEL_FAIL=yes"}, "cockpit")
	if result.err == nil || !strings.Contains(result.stdout, "✗ tunnel failed") || strings.Contains(result.stdout, "done — launch") {
		t.Fatalf("result=%+v", result)
	}
}

func TestCockpitMissingRolesStopsBeforeCommands(t *testing.T) {
	home, path, log := cockpitFixture(t)
	if err := os.RemoveAll(filepath.Join(home, "nixos/dotfiles/ai/roles")); err != nil {
		t.Fatal(err)
	}
	result := runCockpitBinary(t, home, path, nil, "cockpit")
	if result.err == nil || !strings.Contains(result.stdout, "roles missing") || readLog(t, log) != "" {
		t.Fatalf("result=%+v calls=%q", result, readLog(t, log))
	}
}

func cockpitFixture(t *testing.T) (string, string, string) {
	t.Helper()
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	log := filepath.Join(home, "calls.log")
	for _, dir := range []string{bin, filepath.Join(home, "run")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	ai := filepath.Join(home, "nixos/dotfiles/ai")
	for _, rel := range cockpitRoleFiles {
		path := filepath.Join(ai, filepath.FromSlash(rel))
		if filepath.Ext(rel) == ".md" || rel == "instructions.md" {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(rel+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		} else {
			if err := os.MkdirAll(path, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(path, "fixture.txt"), []byte(rel+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	script := `#!/bin/sh
name=${0##*/}; echo "$name|$*" >> "$VMCTL_LOG"
case "$name" in
 pi) printf '%s\n' "${PI_LOCAL-}" ;;
 fish) printf '%s' "${OPENAI_VALUE-}" ;;
 op) printf '%s\n' "${SLACK_VALUE-}" ;;
 rsync) [ "${FAIL_RSYNC-}" = yes ] && exit 1; : > "$HOME/rsync-seen" ;;
 ssh)
   case "$*" in
     *"pi --version"*) printf '%s\n' "${PI_REMOTE-}" ;;
     *"python3 - instructions.md"*)
       if [ -f "$HOME/rsync-seen" ]; then echo "${REMOTE_HASH_AFTER-}"; else echo "${REMOTE_HASH_INITIAL-}"; fi ;;
     *"pgrep -x agentd >/dev/null && echo yes"*) echo "${WAS_RUNNING-no}" ;;
     *'mkdir -p $HOME/.pi/agent/'*) [ "${FAIL_MKDIR-}" = yes ] && exit 1; true ;;
     *"export XDG_DATA_DIRS"*)
       [ "${DAEMON_MODE-}" = fail ] && exit 1
       if [ "${DAEMON_MODE-}" = restart ]; then echo '  restart requested — stopping agentd (pid 42 )'; echo '  listening ✓'; else echo '  already running (pid 42, up 1:23)'; echo '  listening ✓'; fi ;;
   esac ;;
 setsid) : ;;
esac
`
	for _, name := range []string{"ssh", "rsync", "pi", "fish", "op", "setsid"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return home, bin, log
}

func cockpitHealthySocket(t *testing.T, path string) net.Listener {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_, _ = conn.Write([]byte("healthy\n"))
			_ = conn.Close()
		}
	}()
	return listener
}

func runCockpitBinary(t *testing.T, home, path string, extra []string, args ...string) result {
	t.Helper()
	cmd := exec.Command(binary, args...)
	base := []string{"HOME=" + home, "PATH=" + path, "VMCTL_LOG=" + filepath.Join(home, "calls.log"), "XDG_RUNTIME_DIR=" + filepath.Join(home, "run")}
	cmd.Env = append(os.Environ(), append(base, extra...)...)
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return result{stdout.String(), stderr.String(), err}
}
