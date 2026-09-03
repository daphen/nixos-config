package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type output struct {
	Modes []struct {
		Width     int  `json:"width"`
		Height    int  `json:"height"`
		IsCurrent bool `json:"is_current"`
	} `json:"modes"`
	Logical *struct {
		Width  int     `json:"width"`
		Height int     `json:"height"`
		Scale  float64 `json:"scale"`
	} `json:"logical"`
}

type geometry struct {
	screenW, screenH int
	scale            float64
	windowW, windowH int
}

func main() {
	if err := command(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func command(args []string) error {
	if len(args) < 2 || args[0] != "view" {
		return errors.New("usage: mediactl view TARGETS [TYPE]")
	}
	mediaType := "img"
	if len(args) >= 3 {
		mediaType = args[2]
	}
	return view(args[1], mediaType)
}

func view(target, mediaType string) error {
	files := strings.Split(target, "\n")
	logPath := filepath.Join(os.Getenv("HOME"), ".config/qs-chat-clients/media-viewer.log")
	log, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		return err
	}
	fmt.Fprintf(log, "%s  type=%s  n=%d  file=%s\n", time.Now().Format(time.RFC3339), mediaType, len(files), files[0])
	defer log.Close()

	bg := themeBackground()
	geo := focusedGeometry()
	switch mediaType {
	case "img", "gif":
		return viewImage(files, bg, geo)
	case "URL":
		return viewURL(target, log, bg, geo)
	case "video":
		return viewVideo(files, geo)
	case "audio":
		return detached("mpv", append([]string{"--no-terminal", "--force-window=immediate", "--keep-open=yes", "--loop-file=no", fmt.Sprintf("--geometry=%dx120", geo.windowW)}, files...)...)
	default:
		return run(true, "xdg-open", target)
	}
}

func themeBackground() string {
	home := os.Getenv("HOME")
	modeBytes, err := os.ReadFile(filepath.Join(home, ".config/theme_mode"))
	mode := "dark"
	if err == nil {
		mode = strings.TrimSpace(string(modeBytes))
	}
	data, err := os.ReadFile(filepath.Join(home, ".config/themes/colors.json"))
	if err != nil {
		return "181818"
	}
	var colors struct {
		Themes map[string]struct {
			Background struct {
				Primary string `json:"primary"`
			} `json:"background"`
		} `json:"themes"`
	}
	if json.Unmarshal(data, &colors) != nil {
		return "181818"
	}
	bg := strings.ReplaceAll(colors.Themes[mode].Background.Primary, "#", "")
	if bg == "" {
		return "181818"
	}
	return bg
}

func focusedGeometry() geometry {
	g := geometry{screenW: 1920, screenH: 1080, scale: 1}
	out, err := exec.Command("niri", "msg", "--json", "focused-output").Output()
	var parsed output
	if err == nil && json.Unmarshal(out, &parsed) == nil {
		if parsed.Logical != nil && parsed.Logical.Width > 0 && parsed.Logical.Height > 0 {
			g.screenW, g.screenH = parsed.Logical.Width, parsed.Logical.Height
			if parsed.Logical.Scale > 0 {
				g.scale = parsed.Logical.Scale
			}
		} else {
			for _, mode := range parsed.Modes {
				if mode.IsCurrent {
					g.screenW, g.screenH = mode.Width, mode.Height
					break
				}
			}
		}
	}
	g.windowW = g.screenW * 75 / 100
	g.windowH = g.screenH * 85 / 100
	return g
}

func imageGeometry(file string, g geometry) (int, int) {
	out, err := exec.Command("identify", "-format", "%w %h", file+"[0]").Output()
	if err != nil {
		return g.windowW, g.windowH
	}
	fields := strings.Fields(strings.SplitN(string(out), "\n", 2)[0])
	if len(fields) != 2 {
		return g.windowW, g.windowH
	}
	iw, errW := strconv.ParseFloat(fields[0], 64)
	ih, errH := strconv.ParseFloat(fields[1], 64)
	if errW != nil || errH != nil || iw <= 0 || ih <= 0 {
		return g.windowW, g.windowH
	}
	w, h := iw/g.scale, ih/g.scale
	floorW, floorH := float64(g.screenW)*0.60, float64(g.screenH)*0.60
	if w < floorW && h < floorH {
		factor := min(floorW/w, floorH/h, 3)
		w, h = w*factor, h*factor
	}
	if w > float64(g.windowW) {
		h, w = h*float64(g.windowW)/w, float64(g.windowW)
	}
	if h > float64(g.windowH) {
		w, h = w*float64(g.windowH)/h, float64(g.windowH)
	}
	w, h = max(w, 200), max(h, 150)
	return int(w), int(h)
}

func viewImage(files []string, bg string, g geometry) error {
	w, h := imageGeometry(files[0], g)
	if err := detached("imv", append([]string{"-b", bg, "-W", strconv.Itoa(w), "-H", strconv.Itoa(h)}, files...)...); err != nil {
		return err
	}
	return startPositioning()
}

func viewVideo(files []string, g geometry) error {
	return detached("mpv", append([]string{"--loop", "--no-terminal", fmt.Sprintf("--geometry=%dx%d", g.windowW, g.windowH)}, files...)...)
}

func viewURL(target string, log io.Writer, bg string, g geometry) error {
	tryURL := target
	if base, ok := strings.CutSuffix(target, ".gifv"); ok {
		tryURL = base + ".gif"
	}
	ctypeBytes, _ := exec.Command("curl", "-fsIL", "--max-time", "10", "-o", "/dev/null", "-w", "%{content_type}", tryURL).Output()
	ctype := string(ctypeBytes)
	fmt.Fprintf(log, "  HEAD %s -> %s\n", tryURL, ctype)
	isImage := strings.HasPrefix(ctype, "image/")
	if !isImage && !strings.HasPrefix(ctype, "video/") {
		return run(true, "xdg-open", target)
	}
	tmp, err := os.CreateTemp("", "endcord-media.")
	if err != nil {
		return err
	}
	tmp.Close()
	if err := run(true, "curl", "-fsSL", "--max-time", "10", "-o", tmp.Name(), tryURL); err != nil {
		os.Remove(tmp.Name())
		return run(true, "xdg-open", target)
	}
	if isImage {
		return viewImage([]string{tmp.Name()}, bg, g)
	}
	return viewVideo([]string{tmp.Name()}, g)
}

func detached(name string, args ...string) error {
	return run(false, "setsid", append([]string{"-f", name}, args...)...)
}

func startPositioning() error {
	script := `for delay in 0.05 0.05 0.05 0.1 0.15 0.3 0.6; do
 sleep "$delay"
 pid=$(pgrep -n -x imv-wayland || pgrep -n -x imv)
 [ -n "$pid" ] && imv-msg "$pid" center
done`
	return run(false, "setsid", "-f", "sh", "-c", script)
}

func run(visible bool, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if visible {
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	}
	return cmd.Run()
}
