package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

type notification struct {
	ID      json.Number    `json:"id"`
	App     string         `json:"app_name"`
	Summary string         `json:"summary"`
	Hints   map[string]any `json:"hints"`
}

var cockpitTitle = regexp.MustCompile(`^(Cockpit|Heidr|Claude) · (.*)$`)
var worktreeSummary = regexp.MustCompile(`lovable\.daphen-\S+`)

func runNotification(args []string) error {
	if len(args) > 0 && args[0] == "--past" {
		return runPastNotification(args[1:])
	}
	if len(args) == 0 || args[0] == "" {
		return nil
	}
	id, err := notificationNumber(args[0])
	if err != nil {
		return err
	}
	n, ok, err := activeNotification(id)
	if err != nil {
		return err
	}
	if !ok {
		return nil
	}
	return dispatchActiveNotification(args[0], n)
}

func runPastNotification(args []string) error {
	field := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	app, summary, windowID, scope, session := field(0), field(1), field(2), field(3), field(4)
	switch app {
	case "endcord", "Discord", "discord":
		return notificationExec(notificationCommand("niri-jump-or-exec"), "title:dsqrd", notificationCommand("launch-discord-client"))
	case "Slack", "slack", "slk":
		return notificationExec(notificationCommand("niri-jump-or-exec"), "Slack", "slack")
	case "mlqs":
		return notificationExec(notificationCommand("niri-jump-or-exec"), "title:mlqs", notificationCommand("launch-mail-client"))
	case "kitty":
		name := session
		if name == "" {
			name = cockpitContext(summary)
		}
		if focusCockpitSession(name, scope) || focusLegacyCockpit(summary) {
			return nil
		}
		if name != "" {
			if err := writeAgentJump(name); err != nil {
				return err
			}
			_ = runVisible(notificationCommand("cockpit-focus"), "nvim")
		} else if windowID != "" && windowID != "null" {
			_ = niriAction(io.Discard, io.Discard, "focus-window", "--id", windowID)
		} else {
			focusWorktreeFromSummary(summary)
		}
		return nil
	case "agent-rail":
		name := session
		if name == "" {
			name = strings.TrimPrefix(summary, "agent · ")
			if name == summary {
				name = ""
			}
		}
		if name != "" && focusCockpitSession(name, scope) {
			return nil
		}
		if name != "" {
			return writeAgentJump(name)
		}
		return nil
	default:
		focusAppWindow(app)
		return nil
	}
}

func activeNotification(id *big.Rat) (notification, bool, error) {
	data, _ := quickshellCall("", "notifications", "list")
	if len(bytes.TrimSpace(data)) == 0 {
		return notification{}, false, nil
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var notifications []notification
	if err := decoder.Decode(&notifications); err != nil {
		return notification{}, false, err
	}
	for _, candidate := range notifications {
		value, err := notificationNumber(string(candidate.ID))
		if err == nil && value.Cmp(id) == 0 {
			return candidate, true, nil
		}
	}
	return notification{}, false, nil
}

func notificationNumber(value string) (*big.Rat, error) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	var decoded any
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	if _, ok := decoded.(json.Number); !ok {
		return nil, errors.New("notification id must be numeric")
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return nil, errors.New("invalid notification id")
	}
	rational, ok := new(big.Rat).SetString(value)
	if !ok {
		return nil, errors.New("invalid notification id")
	}
	return rational, nil
}

func dispatchActiveNotification(id string, n notification) error {
	invokeDismiss := func() {
		_, _ = quickshellCall("", "notifications", "invoke", id)
		_, _ = quickshellCall("", "notifications", "dismiss", id)
	}
	switch n.App {
	case "endcord", "Discord", "discord":
		invokeDismiss()
		return notificationExec(notificationCommand("niri-jump-or-exec"), "title:dsqrd", notificationCommand("launch-discord-client"))
	case "Slack", "slack", "slk":
		invokeDismiss()
		return notificationExec(notificationCommand("niri-jump-or-exec"), "Slack", "slack")
	case "mlqs":
		invokeDismiss()
		return notificationExec(notificationCommand("niri-jump-or-exec"), "title:mlqs", notificationCommand("launch-mail-client"))
	case "kitty":
		name, scope := hintString(n, "cockpit-context"), hintString(n, "cockpit-scope")
		if name == "" {
			name = cockpitContext(n.Summary)
		}
		if focusCockpitSession(name, scope) || focusLegacyCockpit(n.Summary) {
			_, _ = quickshellCall("", "notifications", "dismiss", id)
			return nil
		}
		if name == "" {
			return notificationExec(notificationCommand("kitty-osc-jump"), id)
		}
		if err := writeAgentJump(name); err != nil {
			return err
		}
		_ = runVisible(notificationCommand("cockpit-focus"), "nvim")
		_, _ = quickshellCall("", "notifications", "dismiss", id)
		return nil
	case "agent-rail":
		name := strings.TrimPrefix(n.Summary, "agent · ")
		if name == n.Summary {
			name = ""
		}
		if name != "" && focusCockpitSession(name, hintString(n, "cockpit-scope")) {
			_, _ = quickshellCall("", "notifications", "dismiss", id)
			return nil
		}
		if name != "" {
			if err := writeAgentJump(name); err != nil {
				return err
			}
		}
		_, _ = quickshellCall("", "notifications", "dismiss", id)
		return nil
	default:
		invokeDismiss()
		time.Sleep(50 * time.Millisecond)
		var focused niriWindow
		_ = niriJSON("focused-window", &focused)
		if !appMatches(focused.AppID, n.App) {
			focusAppWindow(n.App)
		}
		return nil
	}
}

func hintString(n notification, key string) string {
	value, _ := n.Hints[key].(string)
	return value
}

func focusAppWindow(app string) {
	windows, err := niriWindows()
	if err != nil {
		return
	}
	for _, window := range windows {
		if window.AppID != "" && appMatches(window.AppID, app) {
			_ = niriAction(io.Discard, io.Discard, "focus-window", "--id", json.Number(stringID(window.ID)).String())
			return
		}
	}
}

func stringID(id uint64) string {
	return new(big.Int).SetUint64(id).String()
}

func appMatches(windowApp, notificationApp string) bool {
	window, app := strings.ToLower(windowApp), strings.ToLower(notificationApp)
	switch app {
	case "helium", "chromium", "chrome", "firefox":
		app = "browser"
	}
	return window != "" && (strings.Contains(window, app) || strings.Contains(app, window))
}

func focusCockpitSession(name, scope string) bool {
	if name == "" {
		return false
	}
	instances, err := quickshellInstances()
	if err != nil {
		return false
	}
	for _, instance := range instances {
		if instance.PID == 0 {
			continue
		}
		mode, _ := timedQuickshellCall(instance.ID, "cockpit", "scopeMode")
		modeText := strings.TrimRight(string(mode), "\n")
		if (modeText != "personal" && modeText != "work") || (scope != "" && scope != modeText) {
			continue
		}
		sessions, _ := timedQuickshellCall(instance.ID, "cockpit", "sessions")
		if !strings.Contains(string(sessions), "/"+name+" ") {
			continue
		}
		title, _ := timedQuickshellCall(instance.ID, "cockpit", "title")
		if _, err := timedQuickshellCall(instance.ID, "cockpit", "selectSession", name); err != nil {
			continue
		}
		windows, _ := niriWindows()
		for _, window := range windows {
			if window.Title == strings.TrimRight(string(title), "\n") {
				_ = niriAction(io.Discard, io.Discard, "focus-window", "--id", stringID(window.ID))
				break
			}
		}
		return true
	}
	return false
}

func timedQuickshellCall(instance, target, method string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	command := []string{"ipc", "-i", instance, "call", target, method}
	command = append(command, args...)
	return exec.CommandContext(ctx, "qs", command...).Output()
}

func cockpitContext(summary string) string {
	match := cockpitTitle.FindStringSubmatch(summary)
	if len(match) == 0 {
		return ""
	}
	return strings.TrimPrefix(match[2], "lovable.daphen-")
}

func focusLegacyCockpit(summary string) bool {
	name := cockpitContext(summary)
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = "/tmp"
	}
	socket := filepath.Join(runtimeDir, "kitty-cockpit-nvim")
	info, err := os.Stat(socket)
	if name == "" || err != nil || info.Mode()&os.ModeSocket == 0 {
		return false
	}
	data, err := commandOutput("kitty", "@", "--to", "unix:"+socket, "ls")
	if err != nil || !kittyHasContext(data, name) {
		return false
	}
	_ = runVisible(notificationCommand("cockpit-switch"), name)
	_ = runVisible(notificationCommand("cockpit-focus"), "nvim")
	return true
}

func kittyHasContext(data []byte, name string) bool {
	var osWindows []struct {
		Tabs []struct {
			Title string `json:"title"`
		} `json:"tabs"`
	}
	if json.Unmarshal(data, &osWindows) != nil {
		return false
	}
	for _, window := range osWindows {
		for _, tab := range window.Tabs {
			if tab.Title == name || strings.HasPrefix(tab.Title, name+"-") {
				return true
			}
		}
	}
	return false
}

func focusWorktreeFromSummary(summary string) {
	match := worktreeSummary.FindString(summary)
	if match == "" {
		return
	}
	workspace := strings.Replace(match, "lovable.daphen-", "lovable-", 1)
	_ = niriAction(io.Discard, io.Discard, "focus-workspace", workspace)
	var workspaces []niriWorkspace
	if niriJSON("workspaces", &workspaces) != nil {
		return
	}
	var workspaceID uint64
	found := false
	for _, candidate := range workspaces {
		if candidate.Name == workspace {
			workspaceID, found = candidate.ID, true
			break
		}
	}
	if !found {
		return
	}
	windows, _ := niriWindows()
	for _, window := range windows {
		if window.WorkspaceID == workspaceID && window.AppID == "claude" {
			_ = niriAction(io.Discard, io.Discard, "focus-window", "--id", stringID(window.ID))
			return
		}
	}
}

func writeAgentJump(name string) error {
	path := os.Getenv("HOME") + "/.local/state/cockpit/agent-jump"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, []byte(name+"\n"), 0o666); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

func notificationCommand(name string) string {
	if dir := os.Getenv("NIRI_SCRIPTS_DIR"); dir != "" {
		return filepath.Join(dir, name)
	}
	return name
}

func notificationExec(name string, args ...string) error {
	path, err := exec.LookPath(name)
	if err != nil {
		return err
	}
	return syscall.Exec(path, append([]string{name}, args...), os.Environ())
}
