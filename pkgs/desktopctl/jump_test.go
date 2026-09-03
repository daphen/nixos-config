package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeDesktop struct {
	dir       string
	actionLog string
	launchLog string
	countFile string
}

func newFakeDesktop(t *testing.T) *fakeDesktop {
	t.Helper()
	dir := t.TempDir()
	f := &fakeDesktop{
		dir:       dir,
		actionLog: filepath.Join(dir, "actions"),
		launchLog: filepath.Join(dir, "launch"),
		countFile: filepath.Join(dir, "count"),
	}
	shell, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(dir, "niri"), "#!"+shell+"\n"+`printf '%s\n' "$*" >> "$FAKE_ACTION_LOG"
if [[ "$*" == "msg --json windows" ]]; then
  n=0; [[ -f "$FAKE_COUNT_FILE" ]] && read -r n < "$FAKE_COUNT_FILE"
  n=$((n + 1)); printf '%s' "$n" > "$FAKE_COUNT_FILE"
  if [[ "$n" == 1 ]]; then printf '%s' "$FAKE_WINDOWS_1"; else printf '%s' "$FAKE_WINDOWS_2"; fi
  [[ "$n" == 1 ]] && exit "${FAKE_WINDOWS_1_STATUS:-0}"
  exit "${FAKE_WINDOWS_2_STATUS:-0}"
fi
if [[ "$*" == "msg --json workspaces" ]]; then
  printf '%s' "$FAKE_WORKSPACES"
  exit "${FAKE_WORKSPACES_STATUS:-0}"
fi
if [[ "$*" == "msg action focus-window"* ]]; then exit "${FAKE_FOCUS_STATUS:-0}"; fi
if [[ "$*" == "msg action move-window-to-workspace"* ]]; then exit "${FAKE_MOVE_STATUS:-0}"; fi
`)
	writeExecutable(t, filepath.Join(dir, "launcher"), "#!"+shell+"\n"+`printf '%s\n' "$*" > "$FAKE_LAUNCH_LOG"
`)
	return f
}

func writeExecutable(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func (f *fakeDesktop) run(t *testing.T, first, second, workspaces string, extraEnv []string, args ...string) ([]byte, error) {
	t.Helper()
	cmd := exec.Command(testBinary, append([]string{"niri-jump-or-exec"}, args...)...)
	cmd.Env = append(os.Environ(),
		"PATH="+f.dir,
		"FAKE_ACTION_LOG="+f.actionLog,
		"FAKE_LAUNCH_LOG="+f.launchLog,
		"FAKE_COUNT_FILE="+f.countFile,
		"FAKE_WINDOWS_1="+first,
		"FAKE_WINDOWS_2="+second,
		"FAKE_WORKSPACES="+workspaces,
	)
	cmd.Env = append(cmd.Env, extraEnv...)
	return cmd.CombinedOutput()
}

func (f *fakeDesktop) actions(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.actionLog)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func windowsJSON(focused uint64) string {
	return fmt.Sprintf(`[
 {"id":1,"app_id":"Mail","title":"Inbox — ACME","is_focused":%t,"focus_timestamp":{"secs":10,"nanos":1}},
 {"id":2,"app_id":"mail-beta","title":"inbox — personal","is_focused":%t,"focus_timestamp":{"secs":30,"nanos":1}},
 {"id":3,"app_id":"Mail","title":"Archive","is_focused":%t,"focus_timestamp":{"secs":20,"nanos":1}}
]`, focused == 1, focused == 2, focused == 3)
}

func uniqueSelector(t *testing.T, prefix string) string {
	return fmt.Sprintf("%s-%d-%s", prefix, os.Getpid(), strings.ReplaceAll(t.Name(), "/", "-"))
}

func cleanState(t *testing.T, selector string) {
	t.Helper()
	if err := os.MkdirAll("/tmp/niri-focus-tracker", 0o755); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{trackerStatePath(selector), cycleStatePath(selector)} {
		_ = os.Remove(path)
		t.Cleanup(func() { _ = os.Remove(path) })
	}
}

func TestJumpMatchingAndFocusedCycle(t *testing.T) {
	for _, test := range []struct {
		name     string
		selector string
		focused  uint64
		wantID   string
	}{
		{"exact is case sensitive", "Mail", 0, "3"},
		{"title regex ignores case", "title:^INBOX", 2, "1"},
		{"app regex is case sensitive", "regex:^mail-", 0, "2"},
	} {
		t.Run(test.name, func(t *testing.T) {
			cleanState(t, test.selector)
			f := newFakeDesktop(t)
			if output, err := f.run(t, windowsJSON(test.focused), windowsJSON(test.focused), "[]", nil, test.selector, "unused"); err != nil {
				t.Fatalf("run failed: %v: %s", err, output)
			}
			if got := f.actions(t); !strings.HasSuffix(got, "msg action focus-window --id "+test.wantID+"\n") {
				t.Fatalf("actions:\n%s\nwant focus %s", got, test.wantID)
			}
			state, err := os.ReadFile(cycleStatePath(test.selector))
			if err != nil || string(state) != test.wantID+"\n" {
				t.Fatalf("cycle state %q, %v", state, err)
			}
		})
	}
}

func TestJumpPriorityTrackerThenCycleThenMRU(t *testing.T) {
	selector := uniqueSelector(t, "priority")
	cleanState(t, selector)
	fixture := strings.ReplaceAll(windowsJSON(0), `"Mail"`, `"`+selector+`"`)
	for _, test := range []struct {
		name    string
		tracker string
		cycle   string
		want    string
	}{
		{"tracker", "1", "3", "1"},
		{"stale tracker then cycle", "99", "3", "3"},
		{"stale state then MRU", "99", "98", "3"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFakeDesktop(t)
			if err := os.WriteFile(trackerStatePath(selector), []byte(test.tracker), 0o666); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(cycleStatePath(selector), []byte(test.cycle), 0o666); err != nil {
				t.Fatal(err)
			}
			if output, err := f.run(t, fixture, fixture, "[]", nil, selector, "unused"); err != nil {
				t.Fatalf("run failed: %v: %s", err, output)
			}
			if !strings.HasSuffix(f.actions(t), "msg action focus-window --id "+test.want+"\n") {
				t.Fatalf("actions:\n%s", f.actions(t))
			}
		})
	}
}

func TestJumpHereMovesByNameThenFocuses(t *testing.T) {
	selector := uniqueSelector(t, "here")
	cleanState(t, selector)
	fixture := fmt.Sprintf(`[{"id":7,"app_id":%q,"focus_timestamp":{"secs":1}}]`, selector)
	f := newFakeDesktop(t)
	output, err := f.run(t, "[]", fixture, `[{"idx":4,"name":"work","is_focused":true}]`, []string{"FAKE_MOVE_STATUS=1", "FAKE_FOCUS_STATUS=1"}, "--here", selector, "unused")
	if err != nil {
		t.Fatalf("focus and move failures must be masked by cycle write: %v: %s", err, output)
	}
	want := "msg action move-window-to-workspace --window-id 7 --focus false work\nmsg action focus-window --id 7\n"
	if got := f.actions(t); !strings.HasSuffix(got, want) {
		t.Fatalf("actions:\n%s\nwant suffix:\n%s", got, want)
	}
}

func TestJumpNoMatchStartsSplitCommand(t *testing.T) {
	selector := uniqueSelector(t, "none")
	cleanState(t, selector)
	f := newFakeDesktop(t)
	if output, err := f.run(t, "[]", "[]", "[]", nil, selector, "launcher alpha beta"); err != nil {
		t.Fatalf("run failed: %v: %s", err, output)
	}
	deadline := time.Now().Add(time.Second)
	for {
		data, err := os.ReadFile(f.launchLog)
		if err == nil {
			if string(data) != "alpha beta\n" {
				t.Fatalf("launch args %q", data)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("detached command did not run")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := os.Stat(cycleStatePath(selector)); !os.IsNotExist(err) {
		t.Fatalf("no-match launch wrote cycle state: %v", err)
	}
}

func TestJumpUsesTwoSnapshotsAndRejectsBadSecond(t *testing.T) {
	selector := uniqueSelector(t, "snapshots")
	cleanState(t, selector)
	fixture := fmt.Sprintf(`[{"id":8,"app_id":%q}]`, selector)
	f := newFakeDesktop(t)
	output, err := f.run(t, `not-json`, fixture, "[]", nil, selector, "unused")
	if err != nil {
		t.Fatalf("first snapshot failure should not stop the second: %v: %s", err, output)
	}

	f = newFakeDesktop(t)
	if output, err = f.run(t, fixture, `not-json`, "[]", nil, selector, "unused"); err == nil {
		t.Fatalf("bad second snapshot succeeded: %s", output)
	}
}
