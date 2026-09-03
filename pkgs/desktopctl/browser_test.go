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

type fakeBrowserDesktop struct {
	dir, home, binary, browserLog, actionLog, toolLog string
}

func newFakeBrowserDesktop(t *testing.T) *fakeBrowserDesktop {
	t.Helper()
	dir := t.TempDir()
	f := &fakeBrowserDesktop{dir: dir, home: filepath.Join(dir, "home"), browserLog: filepath.Join(dir, "browser.log"), actionLog: filepath.Join(dir, "actions.log"), toolLog: filepath.Join(dir, "tools.log")}
	shell, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range []string{"bash"} {
		if err := os.Symlink(shell, filepath.Join(dir, tool)); err != nil {
			t.Fatal(err)
		}
	}
	f.binary = filepath.Join(dir, "fake-browser")
	writeExecutable(t, f.binary, "#!"+shell+"\n"+`printf '%s\n' "$*" > "$FAKE_BROWSER_LOG"
printf 'GTK=%s SCHEMA=%s\n' "$GTK_USE_PORTAL" "$GSETTINGS_SCHEMA_DIR" >> "$FAKE_BROWSER_LOG"
exit "${FAKE_BROWSER_STATUS:-0}"
`)
	writeExecutable(t, filepath.Join(dir, "niri"), "#!"+shell+"\n"+`printf '%s\n' "$*" >> "$FAKE_ACTION_LOG"
case "$*" in
  "msg --json windows") printf '%s' "${FAKE_WINDOWS:-[]}" ;;
  "msg --json workspaces") printf '%s' "${FAKE_WORKSPACES:-[]}" ;;
esac
`)
	writeExecutable(t, filepath.Join(dir, "ss"), "#!"+shell+"\n"+`n=0; [[ -f "$FAKE_SS_COUNT" ]] && read -r n < "$FAKE_SS_COUNT"; n=$((n+1)); printf %s "$n" > "$FAKE_SS_COUNT"
if (( n >= ${FAKE_SS_READY_AT:-1} )); then printf 'UNCONN 0 0 127.0.0.1:24915 0.0.0.0:* '; fi
`)
	writeExecutable(t, filepath.Join(dir, "timeout"), "#!"+shell+"\n"+`printf '%s\n' "$*" >> "$FAKE_TOOL_LOG"
if [[ "$*" == "2 spotify_player get key devices" ]]; then printf '%s' "${FAKE_DEVICES:-{\"is_active\":true}}"; fi
`)
	writeExecutable(t, filepath.Join(dir, "kitty"), "#!"+shell+"\n"+`printf 'kitty %s\n' "$*" >> "$FAKE_TOOL_LOG"`)
	configDir := filepath.Join(f.home, ".config/niri/scripts")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	config := fmt.Sprintf(`BROWSER_BIN=%q
export GTK_USE_PORTAL=1
export GSETTINGS_SCHEMA_DIR=/fake/schema
BROWSER_CLASS_PERSONAL=browser-personal-%d
BROWSER_CLASS_WORK=browser-work-%d
BROWSER_USER_DATA_PERSONAL=/data/personal
BROWSER_USER_DATA_WORK=/data/work
BROWSER_PROFILE=Default
BROWSER_FLAGS=(--base "two words")
BROWSER_FLAGS_WORK=(--work-a --work-b=value)
`, f.binary, os.Getpid(), os.Getpid())
	if err := os.WriteFile(filepath.Join(configDir, "browser-config.sh"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *fakeBrowserDesktop) run(t *testing.T, binary string, extra []string, args ...string) ([]byte, error) {
	t.Helper()
	_ = os.Remove(f.browserLog)
	_ = os.Remove(f.actionLog)
	_ = os.Remove(f.toolLog)
	cmd := exec.Command(binary, append([]string{"browser-dispatch"}, args...)...)
	cmd.Env = append(os.Environ(), "HOME="+f.home, "PATH="+f.dir, "FAKE_BROWSER_LOG="+f.browserLog, "FAKE_ACTION_LOG="+f.actionLog, "FAKE_TOOL_LOG="+f.toolLog, "FAKE_SS_COUNT="+filepath.Join(f.dir, "ss-count"), "FAKE_WINDOWS=[]", "FAKE_WORKSPACES=[]")
	cmd.Env = append(cmd.Env, extra...)
	return cmd.CombinedOutput()
}

func readOptional(path string) string {
	data, _ := os.ReadFile(path)
	return string(data)
}

func browserClasses() (string, string) {
	return fmt.Sprintf("browser-personal-%d", os.Getpid()), fmt.Sprintf("browser-work-%d", os.Getpid())
}

func cleanBrowserState(t *testing.T) {
	t.Helper()
	personal, work := browserClasses()
	paths := []string{"/tmp/" + personal + "-window-id", "/tmp/" + work + "-window-id", "/tmp/niri-focus-tracker/app-" + personal, "/tmp/niri-focus-tracker/app-" + work}
	for _, path := range paths {
		_ = os.Remove(path)
		path := path
		t.Cleanup(func() { _ = os.Remove(path) })
	}
}

func TestBrowserProfilePrecedenceAndArgv(t *testing.T) {
	binary := testBinary
	personal, work := browserClasses()
	for _, test := range []struct {
		name string
		env  []string
		args []string
		want string
	}{
		{"last URL and YouTube beat work workspace", []string{`FAKE_WORKSPACES=[{"name":"lovable-ticket","is_focused":true}]`}, []string{"ignored", "--new-window", "https://youtube.com/watch?v=x"}, "--base two words --user-data-dir=/data/personal --profile-directory=Default --class=" + personal + " --new-window https://youtube.com/watch?v=x"},
		{"work URL", nil, []string{"--new-window", "https://github.com/lovablelabs/repo"}, "--base two words --work-a --work-b=value --user-data-dir=/data/work --profile-directory=Default --class=" + work + " --new-window https://github.com/lovablelabs/repo"},
		{"forced profile beats URL", nil, []string{"--profile=work", "--new-window", "https://youtu.be/x"}, "--base two words --work-a --work-b=value --user-data-dir=/data/work --profile-directory=Default --class=" + work + " --new-window https://youtu.be/x"},
		{"app omits class work flags and new window", nil, []string{"--profile=work", "--app", "--new-window", "https://example.com"}, "--base two words --user-data-dir=/data/work --profile-directory=Default --app=https://example.com"},
	} {
		t.Run(test.name, func(t *testing.T) {
			cleanBrowserState(t)
			f := newFakeBrowserDesktop(t)
			if output, err := f.run(t, binary, test.env, test.args...); err != nil {
				t.Fatalf("run: %v: %s", err, output)
			}
			if got := strings.Split(readOptional(f.browserLog), "\n")[0]; got != test.want {
				t.Fatalf("argv %q\nwant %q", got, test.want)
			}
			if !strings.Contains(readOptional(f.browserLog), "GTK=1 SCHEMA=/fake/schema") {
				t.Fatal("config exports did not reach browser")
			}
		})
	}
}

func TestBrowserDecisiveRoutesAvoidUnneededObservations(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{"YouTube beats broad lovable match", []string{"--new-window", "https://youtube.com/watch?v=lovable"}, "--user-data-dir=/data/personal"},
		{"Lovable app uses work directly", []string{"--app", "https://lovable.dev"}, "--user-data-dir=/data/work"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFakeBrowserDesktop(t)
			if output, err := f.run(t, testBinary, nil, test.args...); err != nil {
				t.Fatalf("run: %v: %s", err, output)
			}
			if actions := readOptional(f.actionLog); actions != "" {
				t.Fatalf("decisive route observed desktop state:\n%s", actions)
			}
			if argv := readOptional(f.browserLog); !strings.Contains(argv, test.want) {
				t.Fatalf("browser argv %q does not contain %q", argv, test.want)
			}
		})
	}
}

func TestBrowserWorkspaceFailureSkipsFocusNotLaunch(t *testing.T) {
	f := newFakeBrowserDesktop(t)
	output, err := f.run(t, testBinary, []string{"FAKE_WORKSPACES=not-json"}, "https://youtube.com/watch?v=x")
	if err != nil {
		t.Fatalf("run: %v: %s", err, output)
	}
	actions := readOptional(f.actionLog)
	if !strings.Contains(actions, "msg --json workspaces") || strings.Contains(actions, "msg --json windows") || strings.Contains(actions, "focus-window") {
		t.Fatalf("actions after workspace failure:\n%s", actions)
	}
	if browser := readOptional(f.browserLog); !strings.Contains(browser, "https://youtube.com/watch?v=x") {
		t.Fatalf("browser was not launched: %q", browser)
	}
}

func TestBrowserLastFocusAndHomeWindow(t *testing.T) {
	binary := testBinary
	cleanBrowserState(t)
	personal, work := browserClasses()
	if err := os.MkdirAll("/tmp/niri-focus-tracker", 0o755); err != nil {
		t.Fatal(err)
	}
	for path, value := range map[string]string{"/tmp/niri-focus-tracker/app-" + personal: "11\n", "/tmp/niri-focus-tracker/app-" + work: "22\n", "/tmp/" + personal + "-window-id": "11\n", "/tmp/" + work + "-window-id": "22\n"} {
		if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	f := newFakeBrowserDesktop(t)
	windows := fmt.Sprintf(`[{"id":22,"app_id":%q,"workspace_id":2},{"id":33,"app_id":%q,"workspace_id":1,"is_focused":true}]`, work, work)
	spaces := `[{"id":1,"name":"lovable-main"},{"id":2,"name":"lovable-ticket"}]`
	start := time.Now()
	if output, err := f.run(t, binary, []string{"FAKE_WINDOWS=" + windows, "FAKE_WORKSPACES=" + spaces}, "https://example.com"); err != nil {
		t.Fatalf("run: %v: %s", err, output)
	}
	if actions := readOptional(f.actionLog); !strings.Contains(actions, "msg action focus-window --id 33") {
		t.Fatalf("actions: %s", actions)
	}
	if time.Since(start) < 400*time.Millisecond {
		t.Fatal("browser launched before focus confirmation delay")
	}
}

func TestBrowserSpotifyRoutesAndSpawn(t *testing.T) {
	binary := testBinary
	for _, test := range []struct {
		name, url, playback string
		ready               string
	}{
		{"track focuses existing", "spotify:track:Ab12", "5 spotify_player playback start track --id Ab12", "1"},
		{"locale album uses context", "https://open.spotify.com/intl-en/album/Z9", "5 spotify_player playback start context --id Z9 album", "3"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFakeBrowserDesktop(t)
			_ = os.Remove(filepath.Join(f.dir, "ss-count"))
			env := []string{"FAKE_SS_READY_AT=" + test.ready, `FAKE_WINDOWS=[{"id":7,"app_id":"other","title":"Spotify Player"}]`}
			if output, err := f.run(t, binary, env, test.url); err != nil {
				t.Fatalf("run: %v: %s", err, output)
			}
			tools := readOptional(f.toolLog)
			if !strings.Contains(tools, test.playback) {
				t.Fatalf("tools: %s", tools)
			}
			if test.ready == "1" && !strings.Contains(readOptional(f.actionLog), "focus-window --id 7") {
				t.Fatal("existing Spotify window not focused")
			}
			if test.ready != "1" && !strings.Contains(tools, "kitty --class spotify-player -e spotify_player") {
				t.Fatalf("Spotify TUI not spawned: %s", tools)
			}
		})
	}
}

func TestBrowserSpotifyConnectFallbackAndUnsupported(t *testing.T) {
	binary := testBinary
	f := newFakeBrowserDesktop(t)
	if output, err := f.run(t, binary, []string{"FAKE_DEVICES=[]"}, "spotify:artist:A1"); err != nil {
		t.Fatalf("run: %v: %s", err, output)
	}
	if tools := readOptional(f.toolLog); !strings.Contains(tools, "3 spotify_player connect --name spotify-player") || !strings.Contains(tools, "context --id A1 artist") {
		t.Fatalf("connect/playback: %s", tools)
	}
	f = newFakeBrowserDesktop(t)
	if output, err := f.run(t, binary, nil, "--new-window", "https://open.spotify.com/show/S1"); err != nil {
		t.Fatalf("fallback: %v: %s", err, output)
	}
	if !strings.Contains(readOptional(f.browserLog), "https://open.spotify.com/show/S1") {
		t.Fatal("unsupported Spotify type did not fall through")
	}
}

func TestBrowserReturnsLaunchFailure(t *testing.T) {
	binary := testBinary
	f := newFakeBrowserDesktop(t)
	if _, err := f.run(t, binary, []string{"FAKE_BROWSER_STATUS=9"}, "--new-window", "https://example.com"); err == nil {
		t.Fatal("browser failure was masked")
	}
}
