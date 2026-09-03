package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type notificationDesktop struct {
	dir, log, home, runtime string
}

func newNotificationDesktop(t *testing.T) *notificationDesktop {
	t.Helper()
	dir := t.TempDir()
	f := &notificationDesktop{dir: dir, log: filepath.Join(dir, "log"), home: filepath.Join(dir, "home"), runtime: filepath.Join(dir, "runtime")}
	for _, path := range []string{f.home, f.runtime} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(dir, "qs"), `#!/bin/sh
printf 'qs %s\n' "$*" >> "$LOG"
case "$*" in
  "list -a --json") printf '%s' "${INSTANCES:-[]}" ;;
  "ipc call notifications list") printf '%s' "${NOTIFICATIONS:-[]}" ;;
  *" call cockpit scopeMode") [ -n "$SCOPE_SLEEP" ] && exec `+sleep+` "$SCOPE_SLEEP"; printf '%s' "$SCOPE_MODE" ;;
  *" call cockpit sessions") printf '%s' "$SESSIONS" ;;
  *" call cockpit title") printf '%s' "$COCKPIT_TITLE" ;;
  *" call cockpit selectSession "*) exit "${SELECT_STATUS:-0}" ;;
esac
`)
	writeExecutable(t, filepath.Join(dir, "niri"), `#!/bin/sh
printf 'niri %s\n' "$*" >> "$LOG"
case "$*" in
 "msg --json windows") printf '%s' "${WINDOWS:-[]}" ;;
 "msg --json focused-window") printf '%s' "${FOCUSED_WINDOW:-null}" ;;
 "msg --json workspaces") printf '%s' "${WORKSPACES:-[]}" ;;
esac
`)
	writeExecutable(t, filepath.Join(dir, "kitty"), "#!/bin/sh\nprintf 'kitty %s\\n' \"$*\" >> \"$LOG\"\nprintf '%s' \"${KITTY_WINDOWS:-[]}\"\n")
	for _, name := range []string{"niri-jump-or-exec", "launch-discord-client", "launch-mail-client", "slack", "kitty-osc-jump", "cockpit-focus", "cockpit-switch"} {
		writeExecutable(t, filepath.Join(dir, name), "#!/bin/sh\nprintf 'exec "+name+" %s\\n' \"$*\" >> \"$LOG\"\n")
	}
	return f
}

func (f *notificationDesktop) run(t *testing.T, env map[string]string, args ...string) ([]byte, error) {
	t.Helper()
	cmd := exec.Command(testBinary, append([]string{"notification-dispatch"}, args...)...)
	cmd.Env = []string{"PATH=" + f.dir, "LOG=" + f.log, "HOME=" + f.home, "XDG_RUNTIME_DIR=" + f.runtime}
	for key, value := range env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	return cmd.CombinedOutput()
}

func (f *notificationDesktop) readLog(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.log)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestNotificationActiveAliasesInvokeDismissThenExec(t *testing.T) {
	cases := []struct{ app, target string }{
		{"endcord", "title:dsqrd launch-discord-client"}, {"Discord", "title:dsqrd launch-discord-client"}, {"discord", "title:dsqrd launch-discord-client"},
		{"Slack", "Slack slack"}, {"slack", "Slack slack"}, {"slk", "Slack slack"}, {"mlqs", "title:mlqs launch-mail-client"},
	}
	for _, test := range cases {
		t.Run(test.app, func(t *testing.T) {
			f := newNotificationDesktop(t)
			n := fmt.Sprintf(`[{"id":7,"app_name":%q}]`, test.app)
			if output, err := f.run(t, map[string]string{"NOTIFICATIONS": n}, "7.0"); err != nil {
				t.Fatalf("%v: %s", err, output)
			}
			want := "qs ipc call notifications invoke 7.0\nqs ipc call notifications dismiss 7.0\nexec niri-jump-or-exec " + test.target + "\n"
			if got := f.readLog(t); got != "qs ipc call notifications list\n"+want {
				t.Fatalf("log:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func TestNotificationPastAliasesExecWithoutNotificationIPC(t *testing.T) {
	cases := map[string]string{"endcord": "title:dsqrd launch-discord-client", "Discord": "title:dsqrd launch-discord-client", "discord": "title:dsqrd launch-discord-client", "Slack": "Slack slack", "slack": "Slack slack", "slk": "Slack slack", "mlqs": "title:mlqs launch-mail-client"}
	for app, want := range cases {
		t.Run(app, func(t *testing.T) {
			f := newNotificationDesktop(t)
			if output, err := f.run(t, nil, "--past", app, "summary"); err != nil {
				t.Fatalf("%v: %s", err, output)
			}
			if got := f.readLog(t); got != "exec niri-jump-or-exec "+want+"\n" {
				t.Fatalf("log: %s", got)
			}
		})
	}
}

func TestNotificationNumericIDAndGenericFocus(t *testing.T) {
	f := newNotificationDesktop(t)
	env := map[string]string{
		"NOTIFICATIONS":  `[{"id":1000,"app_name":"Chromium","hints":{"urgency":2,"resident":false}}]`,
		"FOCUSED_WINDOW": `{"app_id":"terminal"}`,
		"WINDOWS":        `[{"id":42,"app_id":"my-browser-beta"}]`,
	}
	if output, err := f.run(t, env, "1e3"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	log := f.readLog(t)
	wantOrder := []string{"notifications invoke 1e3", "notifications dismiss 1e3", "focused-window", "--json windows", "focus-window --id 42"}
	position := -1
	for _, want := range wantOrder {
		next := strings.Index(log[position+1:], want)
		if next < 0 {
			t.Fatalf("missing %q in log:\n%s", want, log)
		}
		position += next + 1
	}
	if _, err := f.run(t, nil, `"7"`); err == nil {
		t.Fatal("string notification ID succeeded")
	}
}

func TestNotificationLiveCockpitSelectsScopedSessionAndTitle(t *testing.T) {
	f := newNotificationDesktop(t)
	env := map[string]string{
		"NOTIFICATIONS": `[{"id":9,"app_name":"agent-rail","summary":"agent · every-9","hints":{"cockpit-scope":"work"}}]`,
		"INSTANCES":     `[{"id":"dead","pid":0},{"id":"live","pid":12}]`,
		"SCOPE_MODE":    "work",
		"SESSIONS":      "work/every-9 active",
		"COCKPIT_TITLE": "Cockpit Work",
		"WINDOWS":       `[{"id":88,"title":"Cockpit Work"}]`,
	}
	if output, err := f.run(t, env, "9"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	log := f.readLog(t)
	for _, want := range []string{"qs ipc -i live call cockpit scopeMode", "sessions", "title", "selectSession every-9", "focus-window --id 88", "notifications dismiss 9"} {
		if !strings.Contains(log, want) {
			t.Fatalf("missing %q in log:\n%s", want, log)
		}
	}
	if strings.Contains(log, "-i dead") {
		t.Fatalf("queried dead instance:\n%s", log)
	}
}

func TestNotificationPastScopedCockpitSummarySelectsSession(t *testing.T) {
	f := newNotificationDesktop(t)
	env := map[string]string{
		"INSTANCES":     `[{"id":"live","pid":12}]`,
		"SCOPE_MODE":    "personal",
		"SESSIONS":      "personal/ai-cockpit active",
		"COCKPIT_TITLE": "Cockpit Personal",
		"WINDOWS":       `[{"id":88,"title":"Cockpit Personal"}]`,
	}
	if output, err := f.run(t, env, "--past", "kitty", "Cockpit · personal/ai-cockpit"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	log := f.readLog(t)
	for _, want := range []string{"scopeMode", "sessions", "selectSession ai-cockpit", "focus-window --id 88"} {
		if !strings.Contains(log, want) {
			t.Fatalf("missing %q in log:\n%s", want, log)
		}
	}
}

func TestNotificationKittyAndAgentRailFallbacksDiffer(t *testing.T) {
	for _, test := range []struct {
		app, summary, hint string
		wantFocus          bool
	}{
		{"kitty", "Cockpit · fallback", `,"hints":{"cockpit-context":"fallback"}`, true},
		{"agent-rail", "agent · fallback", "", false},
	} {
		t.Run(test.app, func(t *testing.T) {
			f := newNotificationDesktop(t)
			n := fmt.Sprintf(`[{"id":2,"app_name":%q,"summary":%q%s}]`, test.app, test.summary, test.hint)
			if output, err := f.run(t, map[string]string{"NOTIFICATIONS": n}, "2"); err != nil {
				t.Fatalf("%v: %s", err, output)
			}
			jump, err := os.ReadFile(filepath.Join(f.home, ".local/state/cockpit/agent-jump"))
			if err != nil || string(jump) != "fallback\n" {
				t.Fatalf("jump %q, %v", jump, err)
			}
			if _, err := os.Stat(filepath.Join(f.home, ".local/state/cockpit/agent-jump.tmp")); !os.IsNotExist(err) {
				t.Fatalf("temporary jump remains: %v", err)
			}
			focused := strings.Contains(f.readLog(t), "exec cockpit-focus nvim")
			if focused != test.wantFocus {
				t.Fatalf("cockpit focus=%t, want %t; log:\n%s", focused, test.wantFocus, f.readLog(t))
			}
		})
	}
	f := newNotificationDesktop(t)
	if output, err := f.run(t, nil, "--past", "kitty", "Cockpit · ignored", "", "work", "super-i"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	jump, err := os.ReadFile(filepath.Join(f.home, ".local/state/cockpit/agent-jump"))
	if err != nil || string(jump) != "super-i\n" || !strings.Contains(f.readLog(t), "exec cockpit-focus nvim") {
		t.Fatalf("Super+i fallback: jump=%q err=%v log=\n%s", jump, err, f.readLog(t))
	}
}

func TestNotificationLegacyKittyAndPlainKittyHandoff(t *testing.T) {
	f := newNotificationDesktop(t)
	socket := filepath.Join(f.runtime, "kitty-cockpit-nvim")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	env := map[string]string{"NOTIFICATIONS": `[{"id":3,"app_name":"kitty","summary":"Heidr · ctx"}]`, "KITTY_WINDOWS": `[{"tabs":[{"title":"ctx-child"}]}]`}
	if output, err := f.run(t, env, "3"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	for _, want := range []string{"kitty @ --to unix:" + socket + " ls", "exec cockpit-switch ctx", "exec cockpit-focus nvim", "notifications dismiss 3"} {
		if !strings.Contains(f.readLog(t), want) {
			t.Fatalf("missing %q:\n%s", want, f.readLog(t))
		}
	}
	f = newNotificationDesktop(t)
	if output, err := f.run(t, map[string]string{"NOTIFICATIONS": `[{"id":4,"app_name":"kitty","summary":"shell"}]`}, "4"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	if got := f.readLog(t); !strings.HasSuffix(got, "exec kitty-osc-jump 4\n") {
		t.Fatalf("missing kitty handoff:\n%s", got)
	}
}

func TestNotificationPastKittyWindowAndWorktreeFallbacks(t *testing.T) {
	f := newNotificationDesktop(t)
	if output, err := f.run(t, nil, "--past", "kitty", "plain", "55"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	if !strings.Contains(f.readLog(t), "focus-window --id 55") {
		t.Fatalf("window hint not focused:\n%s", f.readLog(t))
	}
	f = newNotificationDesktop(t)
	env := map[string]string{"WORKSPACES": `[{"id":7,"name":"lovable-ticket"}]`, "WINDOWS": `[{"id":8,"workspace_id":7,"app_id":"claude"}]`}
	if output, err := f.run(t, env, "--past", "kitty", "build lovable.daphen-ticket failed", ""); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	for _, want := range []string{"focus-workspace lovable-ticket", "focus-window --id 8"} {
		if !strings.Contains(f.readLog(t), want) {
			t.Fatalf("missing %q:\n%s", want, f.readLog(t))
		}
	}
}

func TestNotificationUsesSiblingCommandsAndRejectsMalformedLists(t *testing.T) {
	f := newNotificationDesktop(t)
	siblings := filepath.Join(f.dir, "siblings")
	if err := os.Mkdir(siblings, 0o755); err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(siblings, "niri-jump-or-exec"), "#!/bin/sh\nprintf 'sibling %s\\n' \"$*\" >> \"$LOG\"\n")
	if output, err := f.run(t, map[string]string{"NIRI_SCRIPTS_DIR": siblings}, "--past", "Slack", "summary"); err != nil {
		t.Fatalf("sibling route: %v: %s", err, output)
	}
	if got := f.readLog(t); got != "sibling Slack slack\n" {
		t.Fatalf("sibling route log: %q", got)
	}
	f = newNotificationDesktop(t)
	if _, err := f.run(t, map[string]string{"NOTIFICATIONS": "not-json"}, "7"); err == nil {
		t.Fatal("malformed notification list succeeded")
	}
}

func TestNotificationCockpitCallsTimeOut(t *testing.T) {
	f := newNotificationDesktop(t)
	start := time.Now()
	env := map[string]string{"INSTANCES": `[{"id":"hung","pid":1}]`, "SCOPE_SLEEP": "5", "NOTIFICATIONS": `[{"id":6,"app_name":"agent-rail","summary":"agent · wait"}]`}
	if output, err := f.run(t, env, "6"); err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	if elapsed := time.Since(start); elapsed < 1900*time.Millisecond || elapsed > 3500*time.Millisecond {
		t.Fatalf("timeout took %s; log:\n%s", elapsed, f.readLog(t))
	}
}
