package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var binary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "themectl-test-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	binary = filepath.Join(dir, "theme-manager")
	cmd := exec.Command("go", "build", "-o", binary, ".")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		os.Exit(1)
	}
	os.Exit(m.Run())
}

type fixture struct {
	t      *testing.T
	root   string
	home   string
	themes string
	bin    string
}

func setup(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	f := &fixture{t: t, root: root, home: filepath.Join(root, "home"), themes: filepath.Join(root, "dotfiles/themes/.config/themes"), bin: filepath.Join(root, "bin")}
	for _, dir := range []string{f.home, f.themes, filepath.Join(f.themes, "templates"), filepath.Join(f.themes, "generated"), f.bin} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
	}
	f.mock("jq", "if [ \"$1\" = -r ]; then printf '#DADADA\\n'; fi")
	return f
}

func (f *fixture) mock(name, body string) {
	f.t.Helper()
	path := filepath.Join(f.bin, name)
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(path, []byte(script), 0755); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) write(rel, text string) string {
	f.t.Helper()
	path := filepath.Join(f.root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0644); err != nil {
		f.t.Fatal(err)
	}
	return path
}

func (f *fixture) run(args ...string) (string, error) {
	f.t.Helper()
	cmd := exec.Command(binary, args...)
	cmd.Env = append(os.Environ(), "HOME="+f.home, "THEMES_DIR="+f.themes, "PATH="+f.bin+":/usr/bin:/bin")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (f *fixture) generated(tool, mode string) string {
	return f.write(filepath.Join("dotfiles/themes/.config/themes/generated", tool, mode+".theme"), tool+" theme\n")
}

func TestDependencyHelpAndUnknownCommand(t *testing.T) {
	f := setup(t)
	cmd := exec.Command(binary, "help")
	cmd.Env = append(os.Environ(), "HOME="+f.home, "THEMES_DIR="+f.themes, "PATH="+t.TempDir())
	raw, err := cmd.CombinedOutput()
	if err == nil || string(raw) != "\x1b[0;31m[ERROR]\x1b[0m jq is required but not installed. Please install jq first.\n" {
		t.Fatalf("missing jq: err=%v output=%q", err, raw)
	}
	out, err := f.run("help")
	if err != nil || !strings.Contains(out, "Usage: "+binary+" [COMMAND] [OPTIONS]") || !strings.HasSuffix(out, "\n\n") {
		t.Fatalf("help: err=%v output=%q", err, out)
	}
	out, err = f.run("wat")
	if err == nil || !strings.HasPrefix(out, "\x1b[0;31m[ERROR]\x1b[0m Unknown command: wat\n\nTheme Manager") {
		t.Fatalf("unknown command: err=%v output=%q", err, out)
	}
}

func TestStatusDefaultsAndListsTemplates(t *testing.T) {
	f := setup(t)
	f.write("dotfiles/themes/.config/themes/templates/zeta-light.template", "")
	f.write("dotfiles/themes/.config/themes/templates/alpha.template", "")
	out, err := f.run("status", "ignored")
	want := "=== Theme Status ===\nCurrent Theme: dark\nTheme Mode File: " + filepath.Join(f.home, ".config/theme_mode") + "\nThemes Directory: " + f.themes + "\nColors File: " + filepath.Join(f.themes, "colors.json") + "\n\nAvailable Tools:\n  - alpha\n  - zeta-light\n"
	if err != nil || out != want {
		t.Fatalf("status: err=%v\nwant %q\ngot  %q", err, want, out)
	}
}

func TestGenerateUsesSpecificThenGenericTemplatesAndMasksFailures(t *testing.T) {
	f := setup(t)
	log := filepath.Join(f.root, "commands")
	f.mock("python3", "printf '%s\\n' \"$*\" >> '"+log+"'; if [ \"$6\" = broken ]; then exit 9; fi; while IFS= read -r line || [ -n \"$line\" ]; do printf '%s\\n' \"$line\"; done < \"$2\" > \"$5\"")
	f.write("dotfiles/themes/.config/themes/theme-processor.py", "")
	f.write("dotfiles/themes/.config/themes/colors.json", "{}")
	specific := f.write("dotfiles/themes/.config/themes/templates/editor-light.template", "specific\n")
	generic := f.write("dotfiles/themes/.config/themes/templates/editor.template", "generic\n")
	f.write("dotfiles/themes/.config/themes/templates/broken.template", "broken")
	out, err := f.run("generate", "light")
	if err != nil || !strings.Contains(out, "Generated broken theme") || !strings.Contains(out, "All themes generated for light mode") {
		t.Fatalf("masked generation failure: err=%v output=%q", err, out)
	}
	commands := mustRead(t, log)
	if !strings.Contains(commands, specific+" "+filepath.Join(f.themes, "colors.json")+" light") {
		t.Fatalf("specific template not used: %s", commands)
	}
	if got := mustRead(t, filepath.Join(f.themes, "generated/editor/light.theme")); got != "specific\n" {
		t.Fatalf("specific output = %q", got)
	}
	if _, err := f.run("generate", "dark"); err != nil {
		t.Fatal(err)
	}
	if got := mustRead(t, filepath.Join(f.themes, "generated/editor/dark.theme")); got != "generic\n" {
		t.Fatalf("generic output = %q (template %s)", got, generic)
	}
}

func TestApplyCoversEveryAdapterAndContinuesAfterFailures(t *testing.T) {
	f := setup(t)
	tools := []string{"nvim", "fish", "tmux", "fzf", "tide", "spotify-player", "opencode", "process-compose", "claude-code", "chromium-palette", "newtab", "starship", "clipse", "yazi", "yazi-tmtheme", "quickshell", "quickshell-client", "kitty", "pi", "swaylock", "gtk", "kvantum", "unknown"}
	for _, tool := range tools {
		f.generated(tool, "dark")
	}
	f.write("dotfiles/themes/.config/themes/generated/kitty/light.theme", "kitty light theme\n")
	for _, tool := range []string{"nvim", "spotify-player", "opencode", "clipse", "yazi", "kitty", "swaylock"} {
		os.MkdirAll(filepath.Join(f.home, ".config", tool), 0755)
	}
	for _, dir := range []string{"dotfiles/fish/.config/fish/conf.d", "dotfiles/starship", "dotfiles/quickshell", "home/personal/chromium-palette/src/pages/popup", "home/personal/chromium-palette/node_modules/.bin", "home/personal/newtab/src/newtab", "home/personal/newtab/node_modules/.bin", "home/personal/mlqs/ui/vendor/QsLib"} {
		os.MkdirAll(filepath.Join(f.root, dir), 0755)
	}
	for _, name := range []string{"fish", "fzf"} {
		f.mock(name, "exit 0")
	}
	f.mock("python3", `if [ "$1" = - ]; then printf '{"theme": "custom:dotfiles", "other": true}' > "$2"; printf 'Pinned settings.json theme to custom:dotfiles\n'; fi`)
	f.mock("tmux", "[ \"$1\" = list-sessions ] && exit 1; exit 0")
	os.WriteFile(filepath.Join(f.home, "personal/chromium-palette/node_modules/.bin/vite"), []byte("#!/bin/sh\nexit 1\n"), 0755)
	os.WriteFile(filepath.Join(f.home, "personal/newtab/node_modules/.bin/vite"), []byte("#!/bin/sh\nexit 0\n"), 0755)
	f.mock("npm", "exit 0")
	f.write("home/.claude/settings.json", `{"theme":"dark","other":true}`)
	out, err := f.run("apply", "dark")
	if err != nil || !strings.Contains(out, "Unknown tool: unknown") || !strings.HasSuffix(out, "All themes applied for dark mode\n") {
		t.Fatalf("best-effort apply: err=%v output=%s", err, out)
	}
	checks := map[string]string{
		"home/.config/nvim/colors/custom-theme-dark.lua":               "nvim theme\n",
		"dotfiles/fish/.config/fish/conf.d/z_custom_theme_colors.fish": "fish theme\n",
		"home/.config/fzf/opts.conf":                                   "fzf theme\n",
		"home/.config/process-compose/theme.yaml":                      "process-compose theme\n",
		"home/.claude/themes/dotfiles.json":                            "claude-code theme\n",
		"home/personal/chromium-palette/src/pages/popup/_theme.scss":   "chromium-palette theme\n",
		"home/personal/newtab/src/newtab/theme.generated.css":          "newtab theme\n",
		"dotfiles/starship/.config/starship/starship.toml":             "starship theme\n",
		"home/.config/yazi/syntect.tmTheme":                            "yazi-tmtheme theme\n",
		"dotfiles/qslib/.local/share/qml/QsLib/Theme.qml":              "quickshell-client theme\n",
		"home/personal/mlqs/ui/vendor/QsLib/Theme.qml":                 "quickshell-client theme\n",
		"home/.config/kitty/dark-theme.auto.conf":                      "kitty theme\n",
		"home/.config/kitty/light-theme.auto.conf":                     "kitty light theme\n",
		"home/.config/kitty/no-preference-theme.auto.conf":             "kitty light theme\n",
		"home/.pi/agent/themes/dark.json":                              "pi theme\n",
		"home/.config/gtk-4.0/gtk.css":                                 "gtk theme\n",
		"home/.config/Kvantum/CustomTheme/CustomTheme.kvconfig":        "kvantum theme\n",
	}
	for path, want := range checks {
		if got := mustRead(t, filepath.Join(f.root, path)); got != want {
			t.Errorf("%s = %q, want %q", path, got, want)
		}
	}
	if settings := mustRead(t, filepath.Join(f.home, ".claude/settings.json")); !strings.Contains(settings, `"theme": "custom:dotfiles"`) || !strings.Contains(settings, `"other": true`) {
		t.Errorf("claude settings = %s", settings)
	}
	for _, text := range []string{"Tmux theme generated (will apply on next start)", "chromium-palette rebuild failed", "Rebuilt newtab (reload the tab)", "Applied GTK theme", "Applied Kvantum Qt theme"} {
		if !strings.Contains(out, text) {
			t.Errorf("missing adapter output %q", text)
		}
	}
}

func TestApplyKittySkipsMissingSourceThemes(t *testing.T) {
	f := setup(t)
	f.generated("kitty", "dark")
	target := filepath.Join(f.home, ".config/kitty")
	if err := os.MkdirAll(target, 0755); err != nil {
		t.Fatal(err)
	}
	light := filepath.Join(target, "light-theme.auto.conf")
	if err := os.WriteFile(light, []byte("existing\n"), 0644); err != nil {
		t.Fatal(err)
	}

	out, err := f.run("apply", "dark")
	if err != nil || !strings.Contains(out, "Applied kitty theme (local, OS-following)") {
		t.Fatalf("apply kitty: err=%v output=%q", err, out)
	}
	if got := mustRead(t, filepath.Join(target, "dark-theme.auto.conf")); got != "kitty theme\n" {
		t.Fatalf("dark theme = %q", got)
	}
	if got := mustRead(t, light); got != "existing\n" {
		t.Errorf("missing source changed light theme to %q", got)
	}
	if _, err := os.Stat(filepath.Join(target, "no-preference-theme.auto.conf")); !os.IsNotExist(err) {
		t.Errorf("missing source created no-preference theme: %v", err)
	}
}

func TestSwitchValidationOrderingSystemNiriAndWallpaper(t *testing.T) {
	f := setup(t)
	log := filepath.Join(f.root, "commands")
	for _, name := range []string{"gsettings", "dconf", "systemctl", "fish", "waypaper"} {
		f.mock(name, "printf '%s %s\\n' '"+name+"' \"$*\" >> '"+log+"'")
	}
	f.mock("python3", "while IFS= read -r line || [ -n \"$line\" ]; do printf '%s\\n' \"$line\"; done < \"$2\" > \"$5\"; printf 'python %s\\n' \"$*\" >> '"+log+"'")
	f.write("dotfiles/themes/.config/themes/theme-processor.py", "")
	f.write("dotfiles/themes/.config/themes/colors.json", "{}")
	f.write("dotfiles/themes/.config/themes/templates/process-compose.template", "theme")
	f.write("dotfiles/niri/.config/niri/config.kdl", "layout {\n    border {\n        active-color \"#111111\"\n        inactive-color \"#222222\"\n        active-gradient from=\"#111111\" to=\"#222222\"\n    }\n    tab-indicator {\n        active-color \"#111111\"\n        inactive-color \"#222222\"\n    }\n}\n")
	wall := f.write("wall.png", "png")
	os.MkdirAll(filepath.Join(f.home, ".config/themes"), 0755)
	os.Symlink(wall, filepath.Join(f.home, ".config/themes/wallpaper-dark"))
	out, err := f.run("switch", "dark")
	if err != nil {
		t.Fatalf("switch: %v\n%s", err, out)
	}
	ordered(t, out, "Switching to dark", "Generating all themes", "All themes generated", "Applying all themes", "All themes applied", "Updated dconf", "Applied niri", "Theme switched")
	if got := mustRead(t, filepath.Join(f.home, ".config/theme_mode")); got != "dark\n" {
		t.Fatalf("mode = %q", got)
	}
	niri := mustRead(t, filepath.Join(f.root, "dotfiles/niri/.config/niri/config.kdl"))
	for _, want := range []string{`active-color "#DADADA"`, `inactive-color "#3A3A3A"`, `active-gradient from="#DADADA" to="#DADADA"`, `active-color "#FF570D"`, `inactive-color "#999999"`} {
		if !strings.Contains(niri, want) {
			t.Errorf("niri missing %s:\n%s", want, niri)
		}
	}
	deadline := time.Now().Add(time.Second)
	for !strings.Contains(readIfExists(log), "waypaper --wallpaper "+wall+" --no-post-command") && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	commands := readIfExists(log)
	ordered(t, commands, "gsettings set", "python ", "gsettings set", "dconf write", "waypaper --wallpaper")
	out, err = f.run("switch", "sepia")
	if err == nil || out != "\x1b[0;31m[ERROR]\x1b[0m Invalid theme mode: sepia. Use 'dark' or 'light'\n" {
		t.Fatalf("invalid mode: err=%v output=%q", err, out)
	}
}

func TestToggleAutoDefaultsAndWallpaperWarnings(t *testing.T) {
	f := setup(t)
	f.mock("gsettings", "exit 0")
	f.mock("dconf", "exit 0")
	f.write("home/.config/theme_mode", "dark\n")
	out, err := f.run("toggle")
	if err != nil || !strings.Contains(out, "Switching to light theme") || !strings.Contains(out, "No wallpaper set for light") {
		t.Fatalf("toggle: err=%v output=%s", err, out)
	}
	f.write("home/.config/theme_mode", "bogus\n")
	out, err = f.run()
	if err == nil || !strings.Contains(out, "Auto-detecting system theme: bogus") || !strings.Contains(out, "Invalid theme mode: bogus") {
		t.Fatalf("auto invalid current mode: err=%v output=%s", err, out)
	}
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func readIfExists(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

func ordered(t *testing.T, text string, values ...string) {
	t.Helper()
	position := 0
	for _, value := range values {
		next := strings.Index(text[position:], value)
		if next < 0 {
			t.Fatalf("%q missing after byte %d in:\n%s", value, position, text)
		}
		position += next + len(value)
	}
}
