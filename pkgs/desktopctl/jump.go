package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type hyprlandWindow struct {
	Address        string `json:"address"`
	Title          string `json:"title"`
	Class          string `json:"class"`
	FocusHistoryID int    `json:"focusHistoryID"`
}

func usingHyprland() bool {
	return os.Getenv("HYPRLAND_INSTANCE_SIGNATURE") != ""
}

func hyprlandWindows() ([]hyprlandWindow, error) {
	data, _ := commandOutput("hyprctl", "-j", "clients")
	var windows []hyprlandWindow
	err := json.Unmarshal(data, &windows)
	return windows, err
}

func hyprlandActiveWindow() (hyprlandWindow, error) {
	data, _ := commandOutput("hyprctl", "-j", "activewindow")
	var window hyprlandWindow
	err := json.Unmarshal(data, &window)
	return window, err
}

func hyprlandFocusWindow(stdout, stderr io.Writer, address string) error {
	selector := strconv.Quote("address:" + address)
	code := "hl.dispatch(hl.dsp.focus({ window = " + selector + " }))"
	return runCommand(stdout, stderr, "hyprctl", "eval", code)
}

const jumpUsage = "Usage: jump-or-exec <app-id-or-title-pattern> <command>"

type jumpWindow struct {
	ID             string
	Title          string
	AppID          string
	Focused        bool
	RecencySeconds int64
	RecencyNanos   int64
}

func jumpOrExec(args []string) error {
	here := len(args) > 0 && args[0] == "--here"
	if here {
		args = args[1:]
	}
	if len(args) < 2 || args[0] == "" || args[1] == "" {
		fmt.Println(jumpUsage)
		return fmt.Errorf("missing arguments")
	}

	appID, command := args[0], args[1]
	initial, _ := desktopWindows()
	current := focusedJumpWindowID(initial)
	windows, err := desktopWindows()
	if err != nil {
		return err
	}
	match, err := makeWindowMatcher(appID)
	if err != nil {
		return err
	}

	matches := windows[:0]
	for _, window := range windows {
		if match(window) {
			matches = append(matches, window)
		}
	}
	if len(matches) == 0 {
		startBackground(command)
		return nil
	}

	sort.SliceStable(matches, func(i, j int) bool {
		a, b := matches[i], matches[j]
		return a.RecencySeconds > b.RecencySeconds ||
			a.RecencySeconds == b.RecencySeconds && a.RecencyNanos > b.RecencyNanos
	})
	target := chooseJumpTarget(matches, current, appID)

	if here && !usingHyprland() {
		if workspace := focusedWorkspaceReference(); workspace != "" {
			_ = niriAction(io.Discard, io.Discard, "move-window-to-workspace",
				"--window-id", target, "--focus", "false", workspace)
		}
	}
	_ = focusJumpWindow(os.Stdout, os.Stderr, target)
	return os.WriteFile(cycleStatePath(appID), []byte(target+"\n"), 0o666)
}

func desktopWindows() ([]jumpWindow, error) {
	if usingHyprland() {
		windows, err := hyprlandWindows()
		if err != nil {
			return nil, err
		}
		active, _ := hyprlandActiveWindow()
		result := make([]jumpWindow, 0, len(windows))
		for _, window := range windows {
			result = append(result, jumpWindow{
				ID:             window.Address,
				Title:          window.Title,
				AppID:          window.Class,
				Focused:        window.Address != "" && window.Address == active.Address,
				RecencySeconds: -int64(window.FocusHistoryID),
			})
		}
		return result, nil
	}

	windows, err := niriWindows()
	if err != nil {
		return nil, err
	}
	result := make([]jumpWindow, 0, len(windows))
	for _, window := range windows {
		result = append(result, jumpWindow{
			ID:             strconv.FormatUint(window.ID, 10),
			Title:          window.Title,
			AppID:          window.AppID,
			Focused:        window.Focused,
			RecencySeconds: window.FocusTimestamp.Seconds,
			RecencyNanos:   window.FocusTimestamp.Nanos,
		})
	}
	return result, nil
}

func focusedJumpWindowID(windows []jumpWindow) string {
	for _, window := range windows {
		if window.Focused {
			return window.ID
		}
	}
	return ""
}

func focusJumpWindow(stdout, stderr io.Writer, id string) error {
	if usingHyprland() {
		return hyprlandFocusWindow(stdout, stderr, id)
	}
	return niriAction(stdout, stderr, "focus-window", "--id", id)
}

func makeWindowMatcher(selector string) (func(jumpWindow) bool, error) {
	if pattern, ok := strings.CutPrefix(selector, "title:"); ok {
		re, err := regexp.Compile("(?i:" + pattern + ")")
		if err != nil {
			return nil, err
		}
		return func(window jumpWindow) bool { return re.MatchString(window.Title) }, nil
	}
	if pattern, ok := strings.CutPrefix(selector, "regex:"); ok {
		re, err := regexp.Compile(pattern)
		if err != nil {
			return nil, err
		}
		return func(window jumpWindow) bool { return re.MatchString(window.AppID) }, nil
	}
	return func(window jumpWindow) bool { return window.AppID == selector }, nil
}

func chooseJumpTarget(windows []jumpWindow, current, appID string) string {
	for i, window := range windows {
		if window.ID == current {
			return windows[(i+1)%len(windows)].ID
		}
	}
	for _, path := range []string{trackerStatePath(appID), cycleStatePath(appID)} {
		state, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		wanted := strings.TrimSpace(string(state))
		for _, window := range windows {
			if window.ID == wanted {
				return wanted
			}
		}
	}
	return windows[0].ID
}

func trackerStatePath(appID string) string { return "/tmp/niri-focus-tracker/app-" + appID }
func cycleStatePath(appID string) string   { return "/tmp/niri-cycle-" + appID }
