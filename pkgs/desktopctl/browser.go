package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type browserConfig struct {
	bin, personalClass, workClass, personalData, workData, profile string
	gtkPortal, schemas                                             string
	flags, workFlags                                               []string
}

func loadBrowserConfig() (browserConfig, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return browserConfig{}, err
	}
	path := os.Getenv("BROWSER_CONFIG")
	if path == "" {
		path = filepath.Join(home, ".config/niri/scripts/browser-config.sh")
	}
	code := `source "$1" || exit
printf '%s\0' "$BROWSER_BIN" "$BROWSER_CLASS_PERSONAL" "$BROWSER_CLASS_WORK" "$BROWSER_USER_DATA_PERSONAL" "$BROWSER_USER_DATA_WORK" "$BROWSER_PROFILE" "${GTK_USE_PORTAL:-}" "${GSETTINGS_SCHEMA_DIR:-}" "${#BROWSER_FLAGS[@]}" "${BROWSER_FLAGS[@]}" "${#BROWSER_FLAGS_WORK[@]}" "${BROWSER_FLAGS_WORK[@]}"`
	command := exec.Command("bash", "-c", code, "browser-config", path)
	command.Stderr = os.Stderr
	out, err := command.Output()
	if err != nil {
		return browserConfig{}, err
	}
	parts := bytes.Split(bytes.TrimSuffix(out, []byte{0}), []byte{0})
	if len(parts) < 10 {
		return browserConfig{}, fmt.Errorf("invalid browser config")
	}
	values := make([]string, len(parts))
	for i := range parts {
		values[i] = string(parts[i])
	}
	count, err := strconv.Atoi(values[8])
	if err != nil || len(values) < 10+count {
		return browserConfig{}, fmt.Errorf("invalid browser flags")
	}
	workCount, err := strconv.Atoi(values[9+count])
	if err != nil || len(values) != 10+count+workCount {
		return browserConfig{}, fmt.Errorf("invalid work browser flags")
	}
	return browserConfig{
		bin: values[0], personalClass: values[1], workClass: values[2],
		personalData: values[3], workData: values[4], profile: values[5],
		gtkPortal: values[6], schemas: values[7], flags: values[9 : 9+count],
		workFlags: values[10+count:],
	}, nil
}

var spotifyURI = regexp.MustCompile(`spotify:([a-z]+):([A-Za-z0-9]+)`)
var spotifyWeb = regexp.MustCompile(`open\.spotify\.com/(?:intl-[a-z-]+/)?([a-z]+)/([A-Za-z0-9]+)`)
var spotifyType = regexp.MustCompile(`^(track|album|playlist|artist)$`)
var workURL = regexp.MustCompile(`^https?://(www\.)?github\.com/lovablelabs(/|$)`)
var youtubeURL = regexp.MustCompile(`^https?://((www|m|music)\.)?youtube\.com|^https?://youtu\.be`)

func spotifyTarget(url string) (string, string, bool) {
	if !strings.HasPrefix(url, "spotify:") &&
		!(strings.HasPrefix(url, "http://open.spotify.com/") || strings.HasPrefix(url, "https://open.spotify.com/")) {
		return "", "", false
	}
	match := spotifyURI.FindStringSubmatch(url)
	if match == nil {
		match = spotifyWeb.FindStringSubmatch(url)
	}
	if match == nil || !spotifyType.MatchString(match[1]) {
		return "", "", false
	}
	return match[1], match[2], true
}

func spotifyUp() bool {
	out, _ := commandOutput("ss", "-uln")
	return bytes.Contains(out, []byte(":24915 "))
}

func runSpotify(kind, id string) {
	if spotifyUp() {
		if windows, err := niriWindows(); err == nil {
			for _, window := range windows {
				if strings.Contains(strings.ToLower(window.AppID+" "+window.Title), "spotify") {
					_ = niriAction(io.Discard, io.Discard, "focus-window", "--id", strconv.FormatUint(window.ID, 10))
					break
				}
			}
		}
	} else {
		startDetached("kitty --class spotify-player -e spotify_player")
		for i := 0; i < 60 && !spotifyUp(); i++ {
			time.Sleep(250 * time.Millisecond)
		}
		if !spotifyUp() {
			return
		}
	}
	active := false
	for i := 0; i < 20; i++ {
		out, _ := commandOutput("timeout", "2", "spotify_player", "get", "key", "devices")
		if bytes.Contains(out, []byte(`"is_active":true`)) {
			active = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !active {
		_ = runCommand(io.Discard, io.Discard, "timeout", "3", "spotify_player", "connect", "--name", "spotify-player")
	}
	args := []string{"5", "spotify_player", "playback", "start", "context", "--id", id, kind}
	if kind == "track" {
		args = []string{"5", "spotify_player", "playback", "start", "track", "--id", id}
	}
	_ = runCommand(io.Discard, io.Discard, "timeout", args...)
}

func readShellValue(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimRight(string(data), "\n")
}

func lastBrowserProfile(config browserConfig) string {
	personal, _ := os.ReadFile("/tmp/niri-focus-tracker/app-" + config.personalClass)
	work, _ := os.ReadFile("/tmp/niri-focus-tracker/app-" + config.workClass)
	last := strings.TrimRight(string(append(personal, work...)), "\n")
	if newline := strings.LastIndexByte(last, '\n'); newline >= 0 {
		last = last[newline+1:]
	}
	if last != "" && last == readShellValue("/tmp/"+config.workClass+"-window-id") {
		return "work"
	}
	return "personal"
}

func browserMainWindow(class string, workspaces []niriWorkspace) uint64 {
	windows, err := niriWindows()
	if err != nil {
		return 0
	}
	names := make(map[uint64]string, len(workspaces))
	for _, workspace := range workspaces {
		names[workspace.ID] = workspace.Name
	}
	stored, _ := strconv.ParseUint(readShellValue("/tmp/"+class+"-window-id"), 10, 64)
	var fallback, first uint64
	for _, window := range windows {
		if window.AppID != class {
			continue
		}
		name := names[window.WorkspaceID]
		if name == "lovable-main" {
			return window.ID
		}
		if window.ID == stored {
			fallback = window.ID
		}
		if first == 0 && !strings.HasPrefix(name, "lovable-") {
			first = window.ID
		}
	}
	if fallback != 0 {
		return fallback
	}
	return first
}

func focusBrowserHome(class string, workspaces []niriWorkspace) {
	target := browserMainWindow(class, workspaces)
	if target == 0 {
		return
	}
	id := strconv.FormatUint(target, 10)
	_ = niriAction(io.Discard, io.Discard, "focus-window", "--id", id)
	for i := 0; i < 20; i++ {
		windows, _ := niriWindows()
		found := false
		for _, window := range windows {
			found = found || window.Focused && window.ID == target
		}
		if found {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(400 * time.Millisecond)
}

func runBrowser(args []string) error {
	config, err := loadBrowserConfig()
	if err != nil {
		return err
	}
	if config.gtkPortal != "" {
		_ = os.Setenv("GTK_USE_PORTAL", config.gtkPortal)
	}
	if config.schemas != "" {
		_ = os.Setenv("GSETTINGS_SCHEMA_DIR", config.schemas)
	}
	forced, url := "", ""
	newWindow, app := false, false
	for _, arg := range args {
		switch {
		case strings.HasPrefix(arg, "--profile="):
			forced = strings.TrimPrefix(arg, "--profile=")
		case arg == "--new-window":
			newWindow = true
		case arg == "--app":
			app = true
		default:
			url = arg
		}
	}
	if kind, id, ok := spotifyTarget(url); ok {
		runSpotify(kind, id)
		return nil
	}
	profile := forced
	var workspaces []niriWorkspace
	var workspaceErr error
	if profile == "" {
		switch {
		case youtubeURL.MatchString(url):
			profile = "personal"
		case strings.Contains(url, "lovable") || workURL.MatchString(url):
			profile = "work"
		default:
			profile = lastBrowserProfile(config)
			workspaces, workspaceErr = niriWorkspaces()
			for _, workspace := range workspaces {
				if workspace.Focused && strings.HasPrefix(workspace.Name, "lovable-") {
					profile = "work"
					break
				}
			}
		}
	}
	data, class := config.personalData, config.personalClass
	launch := append([]string{}, config.flags...)
	if profile == "work" {
		data, class = config.workData, config.workClass
	}
	if app {
		launch = append(launch, "--user-data-dir="+data, "--profile-directory="+config.profile, "--app="+url)
	} else {
		if profile == "work" {
			launch = append(launch, config.workFlags...)
		}
		if !newWindow {
			if workspaces == nil {
				workspaces, workspaceErr = niriWorkspaces()
			}
			if workspaceErr == nil {
				focusBrowserHome(class, workspaces)
			}
		}
		launch = append(launch, "--user-data-dir="+data, "--profile-directory="+config.profile, "--class="+class)
		if newWindow {
			launch = append(launch, "--new-window")
		}
		launch = append(launch, url)
	}
	path, err := exec.LookPath(config.bin)
	if err != nil {
		return err
	}
	quiet, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer quiet.Close()
	if err := redirectOutput(quiet); err != nil {
		return err
	}
	return syscall.Exec(path, append([]string{config.bin}, launch...), os.Environ())
}
