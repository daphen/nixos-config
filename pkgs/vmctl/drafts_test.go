package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDraftMirrorCLI(t *testing.T) {
	for _, tc := range []struct {
		name, change, want string
		exists             bool
	}{
		{name: "create"},
		{name: "reuse", exists: true},
		{name: "resume", exists: true, change: "paused"},
		{name: "foreign endpoint", exists: true, change: "host", want: "mismatched endpoints"},
		{name: "unsafe mode", exists: true, change: "mode", want: "mismatched endpoints"},
		{name: "ignored files", exists: true, change: "ignore", want: "mismatched endpoints"},
		{name: "conflict", exists: true, change: "conflicts", want: "both versions preserved"},
		{name: "offline", exists: true, change: "offline", want: "not ready"},
		{name: "scan failure", exists: true, change: "scan", want: "scanning or transfer errors"},
		{name: "transfer failure", exists: true, change: "transfer", want: "scanning or transfer errors"},
		{name: "unmanaged local files", change: "unmanaged", want: "not empty"},
		{name: "query failure", change: "query", want: "cannot inspect"},
		{name: "flush failure", exists: true, change: "flush", want: "cannot synchronize"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home, path, log := fixture(t, `printf '%s\n' "$*" >> "$VMCTL_LOG"
case "$*" in
 'sync list --template '*)
   [ ! -f "$HOME/query-fail" ] || exit 1
   if [ -f "$HOME/exists" ]; then read -r data < "$HOME/session.json"; printf '%s\n' "$data"; else printf '[]\n'; fi ;;
 'sync create '*) : > "$HOME/exists" ;;
 'sync resume '*) read -r data < "$HOME/resumed.json"; printf '%s\n' "$data" > "$HOME/session.json" ;;
 'sync flush '*) [ ! -f "$HOME/flush-fail" ] ;;
 *) exit 92 ;;
esac`)
			local := filepath.Join(home, "work", "vm-notes", "inbox")
			alpha := map[string]any{"protocol": "ssh", "user": "vm-user", "host": "vm.example", "path": "/home/vm-user/personal/notes/storage/inbox", "connected": true, "scanned": true}
			beta := map[string]any{"protocol": "local", "path": local, "connected": true, "scanned": true}
			session := map[string]any{"name": "vm-notes-inbox", "mode": "two-way-safe", "alpha": alpha, "beta": beta, "status": "watching"}
			write := func(name string, data []byte) {
				t.Helper()
				if err := os.WriteFile(filepath.Join(home, name), data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			ready, _ := json.Marshal([]any{session})
			write("resumed.json", append(ready, '\n'))
			switch tc.change {
			case "paused":
				session["paused"] = true
			case "host":
				alpha["host"] = "another.example"
			case "mode":
				session["mode"] = "two-way-resolved"
			case "ignore":
				session["ignore"] = map[string]any{"paths": []string{"*.md"}}
			case "conflicts":
				session["conflicts"] = []any{map[string]any{"root": "draft.md"}}
			case "offline":
				beta["connected"] = false
			case "scan":
				alpha["scanProblems"] = []any{map[string]any{"path": "draft.md", "error": "permission denied"}}
			case "transfer":
				beta["transitionProblems"] = []any{map[string]any{"path": "draft.md", "error": "permission denied"}}
			case "query":
				write("query-fail", nil)
			case "flush":
				write("flush-fail", nil)
			case "unmanaged":
				if err := os.MkdirAll(local, 0o700); err != nil {
					t.Fatal(err)
				}
				write("work/vm-notes/inbox/draft.md", []byte("keep my changes\n"))
			}
			data, _ := json.Marshal([]any{session})
			write("session.json", append(data, '\n'))
			if tc.exists {
				write("exists", nil)
			}
			r := runEnv(t, home, path, []string{"COCKPIT_VM_USER=vm-user", "COCKPIT_VM_HOST=vm.example", "XDG_RUNTIME_DIR=" + home}, "sync", "--drafts")
			calls := readLog(t, log)
			if tc.want != "" {
				if r.err == nil || !strings.Contains(r.stderr, tc.want) || r.stdout != "" {
					t.Fatalf("result=%+v calls=%s", r, calls)
				}
			} else if r.err != nil || strings.TrimSpace(r.stdout) != local {
				t.Fatalf("result=%+v calls=%s", r, calls)
			}
			if tc.name == "create" {
				inOrder(t, calls, "sync list", "sync create --name=vm-notes-inbox --mode=two-way-safe --no-global-configuration", "vm-user@vm.example:/home/vm-user/personal/notes/storage/inbox "+local, "sync flush", "sync list")
			} else if strings.Contains(calls, "sync create") {
				t.Fatalf("unexpected creation: %s", calls)
			}
			if tc.name == "resume" && !strings.Contains(calls, "sync resume") {
				t.Fatalf("did not resume: %s", calls)
			}
			if tc.change == "unmanaged" {
				b, err := os.ReadFile(filepath.Join(local, "draft.md"))
				if err != nil || string(b) != "keep my changes\n" {
					t.Fatalf("local draft changed: %q %v", b, err)
				}
			}
			if _, err := os.Stat(filepath.Join(home, "personal", "notes")); !os.IsNotExist(err) {
				t.Fatal("canonical vault was touched")
			}
		})
	}
}
