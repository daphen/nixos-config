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
	result := runWorktreeBinary(t, home, path, "EvErY-44")
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
		"mirror current and dependencies ready", "✗ playwright override failed (non-fatal)",
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
	inOrder(t, calls, "ssh|-o StrictHostKeyChecking=no", "git worktree add", "ssh|-o StrictHostKeyChecking=no", "tmux new-session",
		"vm-sync|EvErY-44", "git|-C "+mirror+" rev-parse HEAD")
	for _, want := range []string{"nix develop ./nix-config --impure -c ./bin/devenv wt --no-meticulous", "@playwright/mcp@latest", "PLAYWRIGHT_BROWSERS_PATH", "grep -qx '.pi/'", fmt.Sprintf("-L 127.0.0.1:%d:127.0.0.1:%d", web, web), fmt.Sprintf("-L 127.0.0.1:%d:127.0.0.1:%d", api, api)} {
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
	result := runWorktreeBinary(t, home, path, "EVERY-46")
	<-done
	if result.err != nil || !strings.Contains(result.stdout, "registered checkout: "+remote) || !strings.Contains(result.stdout, "HTTP ready") {
		t.Fatalf("result=%+v", result)
	}
	calls := readLog(t, log)
	if strings.Contains(calls, "git worktree add") || strings.Contains(calls, "systemd-run|") || !strings.Contains(calls, "vm-sync|--remote-cwd "+remote+" EVERY-46") {
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
	if result.err == nil || !strings.Contains(result.stdout, "install-failed") || !strings.Contains(result.stdout, "mirror not current or dependencies not ready") || !strings.Contains(result.stdout, "new agent was not spawned") {
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
	script := matchingTunnelScript(web, api) + fmt.Sprintf(`
case "${0##*/}|$*" in
  "ssh|"*"process-compose-wt-"*) printf '/remote/config.yaml\n---VMCTL-CONFIG---\n- WEB_PORT=%d\n- VITE_GO_API_BASE_URL=http://127.0.0.1:%d\n' ;;
esac
`, web, api)
	home, path, _ := worktreeFixture(t, script)
	makeWorktreeMirror(t, home, "lovable.daphen-every-48")
	listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, make(chan map[string]any, 1))
	defer listener.Close()
	result := runWorktreeBinary(t, home, path, "EVERY-48")
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
	result := runWorktreeBinary(t, home, path, "EVERY-49")
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
	for _, name := range []string{"git", "ssh", "direnv", "nohup", "vm-sync", "systemctl", "systemd-run", "ss"} {
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
	cmd := exec.Command(binary, append([]string{"worktree"}, args...)...)
	cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+path, "VMCTL_LOG="+filepath.Join(home, "calls.log"),
		"XDG_RUNTIME_DIR="+filepath.Join(home, "run"), "COCKPIT_VM_USER=tester", "COCKPIT_VM_HOST=test-host")
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return result{stdout.String(), stderr.String(), err}
}
