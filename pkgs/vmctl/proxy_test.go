package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestConnectPersistsSelectedVMWithoutStartingOrRestartingAgents(t *testing.T) {
	home, path, log := cockpitFixture(t)
	env := []string{"COCKPIT_VM_USER=another-user", "COCKPIT_VM_HOST=another-vm.example"}
	for range 2 {
		result := runCockpitBinary(t, home, path, env, "connect")
		if result.err != nil {
			t.Fatalf("result=%+v", result)
		}
	}
	data, err := os.ReadFile(filepath.Join(home, ".config/systemd/user/vm-dev-tunnel.service"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Type=forking", `"-fN"`, `"127.0.0.1:2015:127.0.0.1:2015"`, `"another-user@another-vm.example"`, "ExitOnForwardFailure=yes", "StrictHostKeyChecking=yes", "Restart=on-failure", "WantedBy=default.target"} {
		if !strings.Contains(string(data), want) {
			t.Errorf("unit missing %q: %s", want, data)
		}
	}
	calls := readLog(t, log)
	if strings.Count(calls, "systemctl|--user enable --now vm-dev-tunnel.service") != 2 || strings.Contains(calls, "ssh|") || strings.Contains(calls, "restart") {
		t.Fatalf("unexpected actions: %s", calls)
	}
	result := runCockpitBinary(t, home, path, []string{"COCKPIT_VM_HOST=different-vm.example"}, "connect")
	if result.err == nil || !strings.Contains(result.stderr, "different configuration") {
		t.Fatalf("conflicting VM accepted: %+v", result)
	}
	if after, _ := os.ReadFile(filepath.Join(home, ".config/systemd/user/vm-dev-tunnel.service")); string(after) != string(data) || readLog(t, log) != calls {
		t.Fatal("conflicting VM changed the existing tunnel")
	}
}

func TestConnectRejectsNativeAndPropagatesStartFailure(t *testing.T) {
	home, path, log := cockpitFixture(t)
	result := runCockpitBinary(t, home, path, nil, "--native", "connect")
	if result.err == nil || !strings.Contains(result.stderr, "on the desktop") || readLog(t, log) != "" {
		t.Fatalf("native result=%+v", result)
	}
	if err := os.WriteFile(filepath.Join(path, "systemctl"), []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result = runCockpitBinary(t, home, path, nil, "connect")
	if result.err == nil || strings.Contains(result.stdout, "ready") {
		t.Fatalf("failed service advertised readiness: %+v", result)
	}
}

func TestNativeAppReportsOnlyItsVerifiedRouterURL(t *testing.T) {
	for _, scenario := range []string{"ready", "wrong-api", "bad-asset"} {
		t.Run(scenario, func(t *testing.T) {
			home, path, log := worktreeFixture(t, `echo "${0##*/}|$*" >> "$VMCTL_LOG"; exit 1`)
			checkout := filepath.Join(home, "src/lovable-every-77")
			state := filepath.Join(checkout, ".devenv/state")
			if err := os.MkdirAll(state, 0755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(state, "process-compose-wt-51000.yaml"), []byte("- WEB_PORT=51000\n- VITE_GO_API_BASE_URL=http://127.0.0.1:51002\n"), 0644); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"sh", "cat", "mkdir", "grep"} {
				actual, err := exec.LookPath(name)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(actual, filepath.Join(path, name)); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(path, "tmux"), []byte("#!/bin/sh\n[ \"$1\" != display-message ] || printf '%s\\n' '"+checkout+"'\n"), 0755); err != nil {
				t.Fatal(err)
			}
			listener, _ := worktreeSocket(t, home, `{"sessions":[]}`, nil)
			defer listener.Close()
			requests := make(chan string, 8)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests <- r.Host + r.URL.Path
				switch r.URL.Path {
				case "/config/apps/http/servers":
					api := 51002
					if scenario == "wrong-api" {
						api++
					}
					fmt.Fprintf(w, `{"srv0":{"routes":[{"match":[{"host":["another-owner-every-77.localhost"]}],"handle":[{"routes":[{"handle":[{"upstreams":[{"dial":"localhost:51000"}]}]},{"handle":[{"upstreams":[{"dial":"localhost:%d"}]}]}]}]}]}}`, api)
				case "/":
					fmt.Fprint(w, `<script src="/entry.js"></script>`)
				case "/go-api/health":
					fmt.Fprint(w, `{"status":"ok"}`)
				case "/entry.js":
					if scenario == "bad-asset" {
						w.WriteHeader(404)
					}
				default:
					w.WriteHeader(404)
				}
			}))
			defer server.Close()
			transport := &http.Transport{DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}}
			old := http.DefaultTransport
			http.DefaultTransport = transport
			defer func() { http.DefaultTransport = old; transport.CloseIdleConnections() }()
			t.Setenv("HOME", home)
			t.Setenv("PATH", path)
			t.Setenv("XDG_RUNTIME_DIR", filepath.Join(home, "run"))
			t.Setenv("VMCTL_LOG", log)
			var out, errors strings.Builder
			err := command([]string{"--native", "worktree", "--app", "EVERY-77"}, &out, &errors)
			if scenario != "ready" {
				if err == nil || strings.Contains(out.String(), "VM HTTP ready") {
					t.Fatalf("unverified route advertised: err=%v out=%s", err, out.String())
				}
				return
			}
			if err != nil || !strings.Contains(out.String(), "http://another-owner-every-77.localhost:2015/") || !strings.Contains(out.String(), "VM checks do not verify the desktop connection") {
				t.Fatalf("err=%v out=%s errors=%s", err, out.String(), errors.String())
			}
			for _, expected := range []string{"127.0.0.1:2019/config/apps/http/servers", "another-owner-every-77.localhost:2015/go-api/health", "another-owner-every-77.localhost:2015/", "another-owner-every-77.localhost:2015/entry.js"} {
				select {
				case got := <-requests:
					if got != expected {
						t.Fatalf("request=%q want=%q", got, expected)
					}
				default:
					t.Fatalf("missing request %q", expected)
				}
			}
			if strings.Contains(readLog(t, log), "systemctl|") || strings.Contains(readLog(t, log), "ssh|") {
				t.Fatal("native startup attempted desktop commands")
			}
		})
	}
}
