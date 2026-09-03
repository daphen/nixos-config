package main

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const jumpUsage = "Usage: niri-jump-or-exec <app-id-or-title-pattern> <command>"

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
	current := focusedWindowID()
	windows, err := niriWindows()
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
		a, b := matches[i].FocusTimestamp, matches[j].FocusTimestamp
		return a.Seconds > b.Seconds || a.Seconds == b.Seconds && a.Nanos > b.Nanos
	})
	target := chooseJumpTarget(matches, current, appID)

	if here {
		if workspace := focusedWorkspaceReference(); workspace != "" {
			_ = niriAction(io.Discard, io.Discard, "move-window-to-workspace",
				"--window-id", target, "--focus", "false", workspace)
		}
	}
	_ = niriAction(os.Stdout, os.Stderr, "focus-window", "--id", target)
	return os.WriteFile(cycleStatePath(appID), []byte(target+"\n"), 0o666)
}

func focusedWindowID() string {
	windows, err := niriWindows()
	if err != nil {
		return ""
	}
	for _, window := range windows {
		if window.Focused {
			return strconv.FormatUint(window.ID, 10)
		}
	}
	return ""
}

func makeWindowMatcher(selector string) (func(niriWindow) bool, error) {
	if pattern, ok := strings.CutPrefix(selector, "title:"); ok {
		re, err := regexp.Compile("(?i:" + pattern + ")")
		if err != nil {
			return nil, err
		}
		return func(window niriWindow) bool { return re.MatchString(window.Title) }, nil
	}
	if pattern, ok := strings.CutPrefix(selector, "regex:"); ok {
		re, err := regexp.Compile(pattern)
		if err != nil {
			return nil, err
		}
		return func(window niriWindow) bool { return re.MatchString(window.AppID) }, nil
	}
	return func(window niriWindow) bool { return window.AppID == selector }, nil
}

func chooseJumpTarget(windows []niriWindow, current, appID string) string {
	for i, window := range windows {
		if strconv.FormatUint(window.ID, 10) == current {
			return strconv.FormatUint(windows[(i+1)%len(windows)].ID, 10)
		}
	}
	for _, path := range []string{trackerStatePath(appID), cycleStatePath(appID)} {
		state, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		wanted := strings.TrimSpace(string(state))
		for _, window := range windows {
			if strconv.FormatUint(window.ID, 10) == wanted {
				return wanted
			}
		}
	}
	return strconv.FormatUint(windows[0].ID, 10)
}

func trackerStatePath(appID string) string { return "/tmp/niri-focus-tracker/app-" + appID }
func cycleStatePath(appID string) string   { return "/tmp/niri-cycle-" + appID }
