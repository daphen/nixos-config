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

var binary, fakeBinary string

const fakeSource = `package main
import (
 "fmt"
 "os"
 "os/exec"
 "path/filepath"
 "strings"
)
func main() {
 name := filepath.Base(os.Args[0])
 trace, _ := os.OpenFile(os.Getenv("TRACE"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0666)
 fmt.Fprint(trace, name)
 for _, arg := range os.Args[1:] { fmt.Fprintf(trace, " <%s>", arg) }
 fmt.Fprintln(trace)
 trace.Close()
 switch name {
 case "niri": fmt.Print(os.Getenv("NIRI_JSON"))
 case "identify":
  if os.Getenv("IDENTIFY_FAIL") == "1" { os.Exit(1) }
  dims := os.Getenv("DIMS"); if dims == "" { dims = "640 480" }; fmt.Println(dims)
 case "curl":
  if contains("-fsIL") {
   if os.Getenv("HEAD_FAIL") == "1" { os.Exit(22) }
   ctype := os.Getenv("CTYPE"); if ctype == "" { ctype = "text/html" }; fmt.Print(ctype); return
  }
  if os.Getenv("DOWNLOAD_FAIL") == "1" { os.Exit(22) }
  args := os.Args[1:]
  for i, arg := range args { if arg == "-o" { os.WriteFile(args[i+1], []byte("downloaded"), 0666); return } }
 case "setsid":
  args := os.Args[2:]
  if len(args) > 0 && args[0] == "sh" { cmd := exec.Command(args[0], args[1:]...); if cmd.Start() == nil { cmd.Process.Release() } }
 case "pgrep": fmt.Println("4242")
 }
}
func contains(want string) bool {
 for _, arg := range os.Args[1:] { if strings.Contains(arg, want) { return true } }
 return false
}
`

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "mediactl-test.")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	binary = filepath.Join(dir, "mediactl")
	fakeBinary = filepath.Join(dir, "fake")
	fakeGo := filepath.Join(dir, "fake.go")
	if err := os.WriteFile(fakeGo, []byte(fakeSource), 0o644); err != nil {
		panic(err)
	}
	for _, build := range [][]string{{"go", "build", "-o", binary, "."}, {"go", "build", "-o", fakeBinary, fakeGo}} {
		cmd := exec.Command(build[0], build[1:]...)
		if out, err := cmd.CombinedOutput(); err != nil {
			panic(fmt.Sprintf("build public binary: %v\n%s", err, out))
		}
	}
	os.Exit(m.Run())
}

type fixture struct {
	home, bin, trace string
	env              []string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	f := &fixture{
		home:  filepath.Join(root, "home"),
		bin:   filepath.Join(root, "bin"),
		trace: filepath.Join(root, "trace"),
	}
	if err := os.MkdirAll(filepath.Join(f.home, ".config/themes"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(f.home, ".config/qs-chat-clients"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(f.bin, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(f.home, ".config/theme_mode"), []byte("light\n"), 0o644)
	os.WriteFile(filepath.Join(f.home, ".config/themes/colors.json"), []byte(`{"themes":{"light":{"background":{"primary":"#aabbcc"}}}}`), 0o644)
	for _, name := range []string{"niri", "identify", "curl", "setsid", "pgrep", "imv-msg", "xdg-open", "sleep"} {
		if err := os.Symlink(fakeBinary, filepath.Join(f.bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	f.env = append(os.Environ(), "HOME="+f.home, "PATH="+f.bin+":"+os.Getenv("PATH"), "TRACE="+f.trace)
	return f
}

func (f *fixture) run(t *testing.T, extra []string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(binary, args...)
	cmd.Env = append(f.env, extra...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (f *fixture) traced(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.trace)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(data)
}

func requireContains(t *testing.T, value string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		if !strings.Contains(value, want) {
			t.Errorf("missing %q in:\n%s", want, value)
		}
	}
}

func TestImageMultilineThemeGeometryAndPositioning(t *testing.T) {
	f := newFixture(t)
	niri := `{"logical":{"width":1000,"height":800,"scale":2}}`
	if out, err := f.run(t, []string{"NIRI_JSON=" + niri, "DIMS=400 200"}, "view", "one.png\ntwo.gif", "img"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	trace := f.traced(t)
	requireContains(t, trace,
		"niri <msg> <--json> <focused-output>",
		"identify <-format> <%w %h> <one.png[0]>",
		"setsid <-f> <imv> <-b> <aabbcc> <-W> <600> <-H> <300> <one.png> <two.gif>",
		"setsid <-f> <sh> <-c>")
	deadline := time.Now().Add(2 * time.Second)
	for strings.Count(f.traced(t), "imv-msg <4242> <center>") < 7 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := strings.Count(f.traced(t), "imv-msg <4242> <center>"); got != 7 {
		t.Errorf("position retries = %d, want 7\n%s", got, f.traced(t))
	}
	log, err := os.ReadFile(filepath.Join(f.home, ".config/qs-chat-clients/media-viewer.log"))
	if err != nil {
		t.Fatal(err)
	}
	requireContains(t, string(log), "type=img  n=2  file=one.png")
}

func TestImageUsesCurrentModeAndDefaultTheme(t *testing.T) {
	f := newFixture(t)
	os.Remove(filepath.Join(f.home, ".config/themes/colors.json"))
	niri := `{"modes":[{"width":1200,"height":900,"is_current":true}]}`
	if out, err := f.run(t, []string{"NIRI_JSON=" + niri, "IDENTIFY_FAIL=1"}, "view", "photo.jpg", "gif"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	requireContains(t, f.traced(t), "setsid <-f> <imv> <-b> <181818> <-W> <900> <-H> <765> <photo.jpg>")
}

func TestRemoteImageRewritesGifvAndDownloads(t *testing.T) {
	f := newFixture(t)
	url := "https://cdn.example/clip.gifv"
	if out, err := f.run(t, []string{"CTYPE=image/gif", "NIRI_JSON={}"}, "view", url, "URL"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	trace := f.traced(t)
	requireContains(t, trace,
		"curl <-fsIL> <--max-time> <10> <-o> </dev/null> <-w> <%{content_type}> <https://cdn.example/clip.gif>",
		"curl <-fsSL> <--max-time> <10> <-o> <", "endcord-media.",
		"<https://cdn.example/clip.gif>", "setsid <-f> <imv>")
	log, _ := os.ReadFile(filepath.Join(f.home, ".config/qs-chat-clients/media-viewer.log"))
	requireContains(t, string(log), "HEAD https://cdn.example/clip.gif -> image/gif")
}

func TestRemoteVideoDownloadsAndLoops(t *testing.T) {
	f := newFixture(t)
	if out, err := f.run(t, []string{"CTYPE=video/mp4"}, "view", "https://cdn.example/a.mp4", "URL"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	requireContains(t, f.traced(t), "setsid <-f> <mpv> <--loop> <--no-terminal> <--geometry=1440x918> <", "endcord-media.")
}

func TestRemoteFallbacks(t *testing.T) {
	for _, test := range []struct {
		name  string
		extra []string
	}{
		{"html", []string{"CTYPE=text/html"}},
		{"head failure", []string{"HEAD_FAIL=1"}},
		{"download failure", []string{"CTYPE=image/png", "DOWNLOAD_FAIL=1"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t)
			url := "https://example.test/page"
			if out, err := f.run(t, test.extra, "view", url, "URL"); err != nil {
				t.Fatalf("%v: %s", err, out)
			}
			requireContains(t, f.traced(t), "xdg-open <"+url+">")
		})
	}
}

func TestLocalVideoAudioAndFallbackRouting(t *testing.T) {
	for _, test := range []struct {
		name, mediaType, targets, want string
	}{
		{"video", "video", "a.mp4\nb.webm", "setsid <-f> <mpv> <--loop> <--no-terminal> <--geometry=1440x918> <a.mp4> <b.webm>"},
		{"audio", "audio", "voice.ogg", "setsid <-f> <mpv> <--no-terminal> <--force-window=immediate> <--keep-open=yes> <--loop-file=no> <--geometry=1440x120> <voice.ogg>"},
		{"fallback", "YT", "https://youtu.be/x", "xdg-open <https://youtu.be/x>"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t)
			if out, err := f.run(t, nil, "view", test.targets, test.mediaType); err != nil {
				t.Fatalf("%v: %s", err, out)
			}
			requireContains(t, f.traced(t), test.want)
		})
	}
}

func TestUsage(t *testing.T) {
	f := newFixture(t)
	out, err := f.run(t, nil, "view")
	if err == nil {
		t.Fatal("expected failure")
	}
	requireContains(t, out, "usage: mediactl view TARGETS [TYPE]")
}
