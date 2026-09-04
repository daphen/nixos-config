package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	red    = "\033[0;31m"
	green  = "\033[0;32m"
	yellow = "\033[1;33m"
	blue   = "\033[0;34m"
	reset  = "\033[0m"
)

type manager struct {
	home, themes, colors, templates, generated, dotfiles, modeFile string
}

func main() {
	m := newManager()
	if _, err := exec.LookPath("jq"); err != nil {
		m.log(red, "ERROR", "jq is required but not installed. Please install jq first.")
		os.Exit(1)
	}
	if !m.dispatch(os.Args[1:]) {
		os.Exit(1)
	}
}

func newManager() *manager {
	home, _ := os.UserHomeDir()
	themes := os.Getenv("THEMES_DIR")
	if themes == "" {
		themes = filepath.Join(home, ".config/themes")
	}
	themes, _ = filepath.Abs(themes)
	physical, err := filepath.EvalSymlinks(themes)
	if err == nil {
		themes = physical
	}
	return &manager{
		home: home, themes: themes,
		colors: filepath.Join(themes, "colors.json"), templates: filepath.Join(themes, "templates"),
		generated: filepath.Join(themes, "generated"), dotfiles: filepath.Clean(filepath.Join(themes, "../../..")),
		modeFile: filepath.Join(home, ".config/theme_mode"),
	}
}

func (m *manager) log(color, label, text string) {
	fmt.Printf("%s[%s]%s %s\n", color, label, reset, text)
}
func (m *manager) info(s string)    { m.log(blue, "INFO", s) }
func (m *manager) success(s string) { m.log(green, "SUCCESS", s) }
func (m *manager) warning(s string) { m.log(yellow, "WARNING", s) }
func (m *manager) failure(s string) { m.log(red, "ERROR", s) }

func (m *manager) dispatch(args []string) bool {
	command := ""
	if len(args) > 0 {
		command = args[0]
	}
	mode := ""
	if len(args) > 1 {
		mode = args[1]
	}
	switch command {
	case "generate":
		m.generateAll(mode)
	case "apply":
		m.applyAll(mode)
	case "switch":
		return m.switchTheme(mode)
	case "toggle":
		return m.toggle()
	case "auto", "":
		return m.auto()
	case "status":
		m.status()
	case "help", "-h", "--help":
		m.help()
	default:
		m.failure("Unknown command: " + command)
		fmt.Println()
		m.help()
		return false
	}
	return true
}

func (m *manager) current() string {
	b, err := os.ReadFile(m.modeFile)
	if err != nil {
		return "dark"
	}
	return strings.TrimRight(string(b), "\n")
}

func (m *manager) setMode(mode string) {
	bestEffort(os.WriteFile(m.modeFile, []byte(mode+"\n"), 0644))
	m.runQuiet("gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-"+mode)
}

func (m *manager) generateAll(mode string) {
	if mode == "" {
		mode = m.current()
	}
	m.info("Generating all themes for " + mode + " mode...")
	matches, _ := filepath.Glob(filepath.Join(m.templates, "*.template"))
	seen := map[string]bool{}
	for _, path := range matches {
		tool := strings.TrimSuffix(filepath.Base(path), ".template")
		tool = strings.TrimSuffix(strings.TrimSuffix(tool, "-dark"), "-light")
		seen[tool] = true
	}
	for tool := range seen {
		m.generate(tool, mode)
	}
	m.success("All themes generated for " + mode + " mode")
}

func (m *manager) generate(tool, mode string) {
	template := filepath.Join(m.templates, tool+"-"+mode+".template")
	if !isFile(template) {
		template = filepath.Join(m.templates, tool+".template")
	}
	if !isFile(template) {
		m.warning("Template for " + tool + " not found: " + template)
		return
	}
	m.info("Generating " + tool + " theme for " + mode + " mode...")
	outDir := filepath.Join(m.generated, tool)
	bestEffort(os.MkdirAll(outDir, 0755))
	out := filepath.Join(outDir, mode+".theme")
	m.run("python3", filepath.Join(m.themes, "theme-processor.py"), template, m.colors, mode, out, tool)
	m.success("Generated " + tool + " theme: " + out)
}

func (m *manager) applyAll(mode string) {
	if mode == "" {
		mode = m.current()
	}
	m.info("Applying all themes for " + mode + " mode...")
	entries, _ := os.ReadDir(m.generated)
	for _, entry := range entries {
		if isDir(filepath.Join(m.generated, entry.Name())) {
			m.apply(entry.Name(), mode)
		}
	}
	m.success("All themes applied for " + mode + " mode")
}

func (m *manager) target(tool string) (string, string) {
	dot := filepath.Join(m.dotfiles, tool, ".config", tool)
	local := filepath.Join(m.home, ".config", tool)
	if isSymlink(local) && isDir(dot) {
		return dot, "managed"
	}
	if isDir(local) {
		return local, "local"
	}
	return "", ""
}

func (m *manager) apply(tool, mode string) {
	generated := filepath.Join(m.generated, tool, mode+".theme")
	if !isFile(generated) {
		m.failure("Generated theme file not found: " + generated)
		return
	}
	copyTo := func(dst string) {
		os.MkdirAll(filepath.Dir(dst), 0755)
		bestEffort(copyFile(generated, dst))
	}
	switch tool {
	case "nvim":
		if target, label := m.target(tool); target != "" {
			copyTo(filepath.Join(target, "colors", "custom-theme-"+mode+".lua"))
			m.success("Applied Neovim " + mode + " theme (" + label + ")")
		}
	case "fish":
		if has("fish") {
			conf := filepath.Join(m.dotfiles, "fish/.config/fish/conf.d")
			if isDir(conf) {
				copyTo(filepath.Join(conf, "z_custom_theme_colors.fish"))
				m.success("Fish theme generated + persisted to conf.d/z_custom_theme_colors.fish")
			} else {
				m.success("Fish theme generated (dotfiles conf.d not found; live shells only)")
			}
		}
	case "tmux":
		if has("tmux") {
			if m.runQuiet("tmux", "list-sessions") {
				m.run("tmux", "source-file", generated)
				m.success("Applied Tmux theme")
			} else {
				m.success("Tmux theme generated (will apply on next start)")
			}
		}
	case "fzf":
		if has("fzf") {
			link := filepath.Join(m.home, ".config/fzf/opts.conf")
			os.MkdirAll(filepath.Dir(link), 0755)
			os.Remove(link)
			os.Symlink(generated, link)
			m.success("Applied FZF theme (symlinked to " + link + ")")
		}
	case "tide":
		if has("fish") {
			m.run("fish", "-c", "source '"+generated+"'")
			m.success("Applied Tide prompt theme")
		}
	case "spotify-player", "clipse", "yazi", "swaylock":
		if target, label := m.target(tool); target != "" {
			name, suffix := "theme.toml", ""
			switch tool {
			case "spotify-player":
				suffix = ", restart required"
			case "clipse":
				name = "custom_theme.json"
			case "yazi":
				suffix = ", new instances pick it up"
			case "swaylock":
				name = "config"
			}
			copyTo(filepath.Join(target, name))
			m.success("Applied " + tool + " theme (" + label + suffix + ")")
		}
	case "opencode":
		if target, label := m.target(tool); target != "" {
			copyTo(filepath.Join(target, "themes/customtheme.json"))
			m.success("Applied opencode theme (" + label + ")")
		}
	case "process-compose":
		copyTo(filepath.Join(m.home, ".config/process-compose/theme.yaml"))
		m.success("Applied process-compose theme (local)")
	case "btop":
		if target, label := m.target(tool); target != "" {
			copyTo(filepath.Join(target, "themes/custom.theme"))
			m.success("Applied btop theme (" + label + ", new instances pick it up)")
		}
	case "claude-code":
		copyTo(filepath.Join(m.home, ".claude/themes/dotfiles.json"))
		m.success("Wrote claude-code " + mode + " theme to dotfiles.json")
		m.pinClaudeTheme()
	case "chromium-palette":
		repo := filepath.Join(m.home, "personal/chromium-palette")
		if !isDir(repo) {
			m.warning("chromium-palette repo not found at " + repo)
			return
		}
		copyTo(filepath.Join(repo, "src/pages/popup/_theme.scss"))
		m.success("Wrote chromium-palette " + mode + " theme to _theme.scss")
		if !isExecutable(filepath.Join(repo, "node_modules/.bin/vite")) {
			m.info("chromium-palette: install deps then run vite build to pick up the theme")
			break
		}
		if m.runInQuiet(repo, "./node_modules/.bin/vite", "build") {
			m.success("Rebuilt chromium-palette (reload at chrome://extensions)")
		} else {
			m.warning("chromium-palette rebuild failed; run vite build manually")
		}
	case "newtab":
		repo := filepath.Join(m.home, "personal/newtab")
		if !isDir(repo) {
			m.warning("newtab repo not found at " + repo)
			return
		}
		copyTo(filepath.Join(repo, "src/newtab/theme.generated.css"))
		m.success("Wrote newtab theme.generated.css")
		if !isExecutable(filepath.Join(repo, "node_modules/.bin/vite")) {
			m.info("newtab: install deps then npm run build to pick up the theme")
			break
		}
		if m.runInQuiet(repo, "npm", "run", "build") {
			m.success("Rebuilt newtab (reload the tab)")
		} else {
			m.warning("newtab rebuild failed; run npm run build manually")
		}
	case "starship":
		target, label := filepath.Join(m.home, ".config/starship.toml"), "local"
		if isDir(filepath.Join(m.dotfiles, "starship")) {
			target, label = filepath.Join(m.dotfiles, "starship/.config/starship/starship.toml"), "managed"
		}
		copyTo(target)
		m.success("Applied Starship theme (" + label + ")")
	case "yazi-tmtheme":
		if target, _ := m.target("yazi"); target != "" {
			copyTo(filepath.Join(target, "syntect.tmTheme"))
			m.success("Applied yazi syntect theme (preview highlighting)")
		}
	case "quickshell":
		if isDir(filepath.Join(m.dotfiles, "quickshell")) {
			target := filepath.Join(m.dotfiles, "quickshell/.config/quickshell/modules/Theme.qml")
			copyTo(target)
			m.success("Applied Quickshell theme (managed)")
		}
	case "quickshell-client":
		target := filepath.Join(m.dotfiles, "qslib/.local/share/qml/QsLib/Theme.qml")
		copyTo(target)
		for _, app := range []string{"mlqs", "slqs", "dsqrd"} {
			vend := filepath.Join(m.home, "personal", app, "ui/vendor/QsLib")
			if isDir(vend) {
				copyTo(filepath.Join(vend, "Theme.qml"))
			}
		}
		m.success("Applied QsLib client theme (managed + vendored)")
	case "kitty":
		if target, label := m.target(tool); target != "" {
			copies := []struct{ source, destination string }{
				{"dark.theme", "dark-theme.auto.conf"},
				{"light.theme", "light-theme.auto.conf"},
				{"light.theme", "no-preference-theme.auto.conf"},
			}
			for _, copy := range copies {
				source := filepath.Join(m.generated, "kitty", copy.source)
				if isFile(source) {
					bestEffort(copyFile(source, filepath.Join(target, copy.destination)))
				}
			}
			m.success("Applied kitty theme (" + label + ", OS-following)")
		}
	case "pi":
		copyTo(filepath.Join(m.home, ".pi/agent/themes", mode+".json"))
		m.success("Applied Pi coding agent " + mode + " theme")
	case "gtk":
		m.applyGTK(generated, mode)
	case "kvantum":
		m.applyKvantum(generated)
	default:
		m.warning("Unknown tool: " + tool)
	}
}

func (m *manager) pinClaudeTheme() {
	path := filepath.Join(m.home, ".claude/settings.json")
	if !isFile(path) {
		return
	}
	script := `import json, sys
path = sys.argv[1]
with open(path) as f:
    s = json.load(f)
if s.get("theme") != "custom:dotfiles":
    s["theme"] = "custom:dotfiles"
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
    print("Pinned settings.json theme to custom:dotfiles")
`
	cmd := exec.Command("python3", "-", path)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = strings.NewReader(script), os.Stdout, os.Stderr
	cmd.Run()
}

func (m *manager) applyGTK(generated, mode string) {
	dark, name := "false", "Adwaita"
	if mode == "dark" {
		dark, name = "true", "Adwaita-dark"
	}
	settings := fmt.Sprintf("[Settings]\ngtk-application-prefer-dark-theme=%s\ngtk-cursor-theme-name=Adwaita\ngtk-cursor-theme-size=24\ngtk-theme-name=%s\ngtk-font-name=BerkeleyMono Nerd Font 11\n", dark, name)
	for _, version := range []string{"gtk-3.0", "gtk-4.0"} {
		dir := filepath.Join(m.home, ".config", version)
		bestEffort(os.MkdirAll(dir, 0755))
		bestEffort(copyFile(generated, filepath.Join(dir, "gtk.css")))
		bestEffort(os.WriteFile(filepath.Join(dir, "settings.ini"), []byte(settings), 0644))
	}
	m.success("Applied GTK theme (gtk-3.0 + gtk-4.0)")
}

func (m *manager) applyKvantum(generated string) {
	base := filepath.Join(m.home, ".config/Kvantum")
	dir := filepath.Join(base, "CustomTheme")
	bestEffort(os.MkdirAll(dir, 0755))
	bestEffort(copyFile(generated, filepath.Join(dir, "CustomTheme.kvconfig")))
	bestEffort(os.WriteFile(filepath.Join(base, "kvantum.kvconfig"), []byte("[General]\ntheme=CustomTheme\n"), 0644))
	svg := filepath.Join(dir, "CustomTheme.svg")
	if !isFile(svg) {
		bestEffort(os.WriteFile(svg, []byte("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"><rect width=\"1\" height=\"1\" fill=\"none\"/></svg>\n"), 0644))
	}
	m.success("Applied Kvantum Qt theme")
}

func (m *manager) switchTheme(mode string) bool {
	if mode != "dark" && mode != "light" {
		m.failure("Invalid theme mode: " + mode + ". Use 'dark' or 'light'")
		return false
	}
	m.info("Switching to " + mode + " theme...")
	m.setMode(mode)
	m.generateAll(mode)
	m.applyAll(mode)
	m.applySystem(mode)
	if !m.wallpaper(mode) {
		return false
	}
	m.success("Theme switched to " + mode + " mode")
	return true
}

func (m *manager) toggle() bool {
	if m.current() == "dark" {
		return m.switchTheme("light")
	}
	return m.switchTheme("dark")
}
func (m *manager) auto() bool {
	mode := m.current()
	m.info("Auto-detecting system theme: " + mode)
	return m.switchTheme(mode)
}

func (m *manager) applySystem(mode string) {
	pref, gtk := "prefer-light", "Adwaita"
	if mode == "dark" {
		pref, gtk = "prefer-dark", "Adwaita-dark"
	}
	if has("dconf") {
		if has("gsettings") {
			m.runQuiet("gsettings", "set", "org.gnome.desktop.interface", "color-scheme", pref)
		} else {
			m.runQuiet("dconf", "write", "/org/gnome/desktop/interface/color-scheme", "'"+pref+"'")
		}
		m.runQuiet("dconf", "write", "/org/gnome/desktop/interface/gtk-theme", "'"+gtk+"'")
		if has("fish") {
			m.runQuiet("fish", "-c", "set -Ux GTK_THEME "+gtk)
		}
		if has("systemctl") {
			m.runQuiet("systemctl", "--user", "set-environment", "GTK_THEME="+gtk)
		}
		m.success("Updated dconf color-scheme=" + pref + ", gtk-theme=" + gtk)
	} else if has("gsettings") {
		m.runQuiet("gsettings", "set", "org.gnome.desktop.interface", "color-scheme", pref)
		m.success("Updated gsettings color-scheme")
	}
	if isFile(filepath.Join(m.home, ".config/Kvantum/kvantum.kvconfig")) {
		m.success("Kvantum Qt theme is configured")
	}
	m.applyNiri(mode)
}

func (m *manager) applyNiri(mode string) {
	live, dot := filepath.Join(m.home, ".config/niri/config.kdl"), filepath.Join(m.dotfiles, "niri/.config/niri/config.kdl")
	if isFile(dot) && pathExists(live) && !isSymlink(live) {
		m.info("Restoring niri/config.kdl symlink (was a regular file)")
		bestEffort(os.Remove(live))
		bestEffort(os.Symlink(dot, live))
	}
	path := dot
	if !isFile(path) {
		path = live
	}
	if !isFile(path) {
		return
	}
	active, inactive := "#6F6F6E", "#E2E2E1"
	if mode == "dark" {
		active, inactive = m.jqColor(".themes.dark.foreground.primary"), "#3A3A3A"
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	s := string(b)
	s = regexp.MustCompile(`active-color "#[0-9a-fA-F]*"`).ReplaceAllString(s, `active-color "`+active+`"`)
	s = regexp.MustCompile(`inactive-color "#[0-9a-fA-F]*"`).ReplaceAllString(s, `inactive-color "`+inactive+`"`)
	lines, border, tab := strings.Split(s, "\n"), false, false
	gradient := regexp.MustCompile(`^( *)active-gradient from="#[0-9a-fA-F]*" to="#[0-9a-fA-F]*"`)
	for i, line := range lines {
		if line == "    border {" {
			border = true
		}
		if line == "    tab-indicator {" {
			tab = true
		}
		if border {
			lines[i] = gradient.ReplaceAllString(line, `${1}active-gradient from="`+active+`" to="`+active+`"`)
		}
		if tab {
			lines[i] = strings.ReplaceAll(strings.ReplaceAll(lines[i], `active-color "`+active+`"`, `active-color "#FF570D"`), `inactive-color "`+inactive+`"`, `inactive-color "#999999"`)
		}
		if line == "    }" {
			border, tab = false, false
		}
	}
	bestEffort(os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644))
	m.success("Applied niri border colors for " + mode + " mode")
}

func (m *manager) jqColor(path string) string {
	cmd := exec.Command("jq", "-r", path, m.colors)
	cmd.Stderr = os.Stderr
	b, _ := cmd.Output()
	return strings.TrimSpace(string(b))
}

func (m *manager) wallpaper(mode string) bool {
	link := filepath.Join(m.home, ".config/themes/wallpaper-"+mode)
	if !pathExists(link) {
		m.warning("No wallpaper set for " + mode + " (symlink " + link + " missing); leaving current wallpaper")
		return true
	}
	target, err := filepath.EvalSymlinks(link)
	if err != nil {
		target = link
	}
	if !isFile(target) {
		m.warning("Wallpaper symlink for " + mode + " points to nonexistent file: " + target)
		return true
	}
	if has("waypaper") {
		before := wallpaperPIDs(target)
		cmd := exec.Command("waypaper", "--wallpaper", target, "--no-post-command")
		cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
		if err := cmd.Run(); err == nil && waitForWallpaper(target, before) {
			return true
		}
		m.warning("Waypaper did not leave a wallpaper process; trying swaybg directly")
	}
	if !has("swaybg") {
		m.failure("Could not apply wallpaper: swaybg is not available")
		return false
	}
	cmd := exec.Command("swaybg", "-i", target, "-m", "fill", "-c", "#ffffff")
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	if err := cmd.Start(); err != nil {
		m.failure("Could not start swaybg: " + err.Error())
		return false
	}
	return cmd.Process.Release() == nil
}

func waitForWallpaper(target string, before map[string]bool) bool {
	for range 10 {
		for pid := range wallpaperPIDs(target) {
			if !before[pid] {
				return true
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

func wallpaperPIDs(target string) map[string]bool {
	pids := map[string]bool{}
	matches, _ := filepath.Glob("/proc/[0-9]*/cmdline")
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		parts := strings.Split(string(data), "\x00")
		isSwaybg, hasTarget := false, false
		for _, part := range parts {
			isSwaybg = isSwaybg || filepath.Base(part) == "swaybg"
			hasTarget = hasTarget || part == target
		}
		if isSwaybg && hasTarget {
			pids[filepath.Base(filepath.Dir(path))] = true
		}
	}
	return pids
}

func (m *manager) status() {
	fmt.Printf("=== Theme Status ===\nCurrent Theme: %s\nTheme Mode File: %s\nThemes Directory: %s\nColors File: %s\n\nAvailable Tools:\n", m.current(), m.modeFile, m.themes, m.colors)
	matches, _ := filepath.Glob(filepath.Join(m.templates, "*.template"))
	for _, path := range matches {
		fmt.Println("  - " + strings.TrimSuffix(filepath.Base(path), ".template"))
	}
}

func (m *manager) help() {
	fmt.Printf(`Theme Manager - Centralized theme management for dotfiles

Usage: %s [COMMAND] [OPTIONS]

Commands:
    generate [MODE]     Generate themes for specified mode (dark/light)
    apply [MODE]        Apply themes for specified mode (dark/light)
    switch [MODE]       Switch to specified theme mode (dark/light)
    toggle              Toggle between light and dark themes
    auto                Auto-detect and apply system theme
    status              Show current theme status
    help                Show this help message

Options:
    MODE                Theme mode: 'dark' or 'light' (auto-detected if not specified)

Examples:
    %s auto             # Auto-detect and apply system theme
    %s switch dark      # Switch to dark theme
    %s toggle           # Toggle between light and dark
    %s generate light   # Generate light theme files only
    %s status           # Show current status

`, os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0])
}

func (m *manager) run(name string, args ...string) bool {
	cmd := exec.Command(name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run() == nil
}
func (m *manager) runQuiet(name string, args ...string) bool {
	return m.runInQuiet("", name, args...)
}
func (m *manager) runInQuiet(dir, name string, args ...string) bool {
	cmd := exec.Command(name, args...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = dir, io.Discard, io.Discard
	return cmd.Run() == nil
}
func bestEffort(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
}
func has(name string) bool        { _, err := exec.LookPath(name); return err == nil }
func isFile(path string) bool     { fi, err := os.Stat(path); return err == nil && fi.Mode().IsRegular() }
func isDir(path string) bool      { fi, err := os.Stat(path); return err == nil && fi.IsDir() }
func pathExists(path string) bool { _, err := os.Stat(path); return err == nil }
func isSymlink(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.Mode()&os.ModeSymlink != 0
}
func isExecutable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0111 != 0
}
func copyFile(src, dst string) error {
	contents, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, contents, 0666)
}
