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

func TestPublicBinary(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "sessionctl")
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build public binary: %v\n%s", err, output)
	}
	bin := filepath.Join(root, "bin")
	mustMkdir(t, bin)
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(bin, "fzf"), "#!"+shell+`
printf '%s\n' "$@" > "$TEST_LOG"
cat > "$TEST_INPUT"
[ -n "${FZF_SELECT:-}" ] || exit 130
sed -n "${FZF_SELECT}p" "$TEST_INPUT"
`)
	writeExecutable(t, filepath.Join(bin, "setsid"), "#!"+shell+`
printf '%s\n' "$@" > "$SETSID_LOG"
`)
	writeExecutable(t, filepath.Join(bin, "glow"), "#!"+shell+"\ncat\n")

	t.Run("picker rows, ordering, labels, timestamps, and id", func(t *testing.T) {
		home := filepath.Join(root, "picker-home")
		projects := filepath.Join(home, ".claude", "projects")
		mustMkdir(t, projects)
		now := time.Now().UTC()
		newer := filepath.Join(projects, "newer.jsonl")
		writeJSONL(t, newer,
			line("user", "/home/daphen/work/lovable.daphen-every-2408-picker", "daphen/every-2408-picker", now.Add(-3*time.Hour), "first request"),
			`{"type":"user","timestamp":"`+now.Add(-2*time.Hour).Format(time.RFC3339Nano)+`","message":{"content":[{"type":"tool_result","text":"ignored"}]}}`,
			line("user", "", "", now.Add(-90*time.Minute), "latest user text"),
			`{"type":"custom-title","customTitle":"My renamed session"}`,
			`{"type":"metadata","timestamp":"`+now.Add(-5*time.Minute).Format(time.RFC3339Nano)+`"}`,
		)
		worktree := filepath.Join(projects, "worktree.jsonl")
		writeJSONL(t, worktree, line("user", "/home/daphen/work/lovable.daphen-every-2409-worktree", "daphen/every-2409-worktree", now.Add(-30*time.Minute), "worktree session"))
		older := filepath.Join(projects, "older.jsonl")
		writeJSONL(t, older,
			line("user", "/tmp/plain", "daphen/topic", now.Add(-time.Hour), "other session"),
			`{"type":"ai-title","aiTitle":"Generated topic"}`,
		)
		mustMkdir(t, filepath.Join(projects, "subagents"))
		writeJSONL(t, filepath.Join(projects, "subagents", "excluded.jsonl"), line("user", "/tmp", "main", now, "must not appear"))
		writeJSONL(t, filepath.Join(projects, "empty.jsonl"), `{"type":"assistant","message":{"content":[{"type":"text","text":"skip"}]}}`)
		_ = os.Chtimes(older, now.Add(-time.Hour), now.Add(-time.Hour))
		_ = os.Chtimes(worktree, now.Add(-30*time.Minute), now.Add(-30*time.Minute))
		_ = os.Chtimes(newer, now, now)

		log := filepath.Join(root, "fzf-args")
		input := filepath.Join(root, "fzf-input")
		result := run(t, binary, []string{"picker", "--id-only"}, env(home, bin, map[string]string{
			"TEST_LOG": log, "TEST_INPUT": input, "FZF_SELECT": "1",
		}))
		if result != "newer\n" {
			t.Fatalf("selected id = %q", result)
		}
		rows := read(t, input)
		assertContains(t, rows, "1\tnewer\t5m ago")
		assertContains(t, rows, "My renamed session")
		assertContains(t, rows, "latest user text")
		assertContains(t, rows, "2\tworktree\t30m ago")
		assertContains(t, rows, "2409-worktree")
		assertContains(t, rows, "3\tolder\t1h ago")
		assertContains(t, rows, "Generated topic")
		if strings.Contains(rows, "ignored") || strings.Contains(rows, "must not appear") {
			t.Fatalf("unfiltered rows:\n%s", rows)
		}
		args := read(t, log)
		for _, expected := range []string{"--with-nth=3", "--height=100%", "--reverse", "--no-sort", "--preview-window=down:60%:wrap:follow", "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up", "ctrl-r:execute", "claude-rename", "--id {2}", "sessionctl preview {1}"} {
			assertContains(t, args, expected)
		}
		if strings.Contains(args, "sed ") || strings.Contains(args, "cut ") {
			t.Fatalf("rename binding still resolves id through shell tools:\n%s", args)
		}
	})

	t.Run("cancellation does not resume", func(t *testing.T) {
		home := filepath.Join(root, "cancel-home")
		mustMkdir(t, filepath.Join(home, ".claude", "projects"))
		writeJSONL(t, filepath.Join(home, ".claude", "projects", "cancel.jsonl"), line("user", "/tmp/cancel", "main", time.Now(), "cancel me"))
		setsidLog := filepath.Join(root, "cancel-setsid")
		result := run(t, binary, []string{"picker"}, env(home, bin, map[string]string{
			"TEST_LOG": filepath.Join(root, "cancel-fzf"), "TEST_INPUT": filepath.Join(root, "cancel-input"), "SETSID_LOG": setsidLog,
		}))
		if result != "" {
			t.Fatalf("cancellation output = %q", result)
		}
		if _, err := os.Stat(setsidLog); !os.IsNotExist(err) {
			t.Fatal("cancellation launched a session")
		}
	})

	t.Run("detached kitty resume", func(t *testing.T) {
		home := filepath.Join(root, "resume-home")
		mustMkdir(t, filepath.Join(home, ".claude", "projects"))
		writeJSONL(t, filepath.Join(home, ".claude", "projects", "resume-id.jsonl"), line("user", "/tmp/resume cwd", "main", time.Now(), "resume me"))
		setsidLog := filepath.Join(root, "resume-setsid")
		run(t, binary, []string{"picker"}, env(home, bin, map[string]string{
			"TEST_LOG": filepath.Join(root, "resume-fzf"), "TEST_INPUT": filepath.Join(root, "resume-input"), "FZF_SELECT": "1", "SETSID_LOG": setsidLog,
		}))
		args := waitRead(t, setsidLog)
		for _, expected := range []string{"-f", "kitty", "--class", "claude", "--working-directory", "/tmp/resume cwd", "-e", "claude", "--resume", "resume-id"} {
			assertContains(t, args, expected)
		}
	})

	t.Run("preview renders latest messages", func(t *testing.T) {
		home := filepath.Join(root, "preview-home")
		mustMkdir(t, home)
		now := time.Now().UTC()
		transcript := filepath.Join(root, "preview.jsonl")
		writeJSONL(t, transcript,
			line("user", home+"/project", "main", now.Add(-2*time.Minute), "hello\nthere"),
			`{"type":"user","timestamp":"`+now.Add(-time.Minute).Format(time.RFC3339Nano)+`","message":{"content":"<system hidden>"}}`,
			`{"type":"assistant","timestamp":"`+now.Add(-30*time.Second).Format(time.RFC3339Nano)+`","message":{"content":[{"type":"text","text":"answer"},{"type":"text","text":"ignored second block"}]}}`,
		)
		meta := filepath.Join(root, "meta")
		if err := os.WriteFile(meta, []byte("preview-session\t"+home+"/project\t"+transcript+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		result := run(t, binary, []string{"preview", "1", meta}, env(home, bin, nil))
		for _, expected := range []string{"# ~/project", "`preview-…`", "30s ago", "**You**", "> hello", "> there", "**Claude**", "answer"} {
			assertContains(t, result, expected)
		}
		if strings.Contains(result, "system hidden") || strings.Contains(result, "ignored second block") {
			t.Fatalf("preview filtering failed:\n%s", result)
		}
	})
}

func line(kind, cwd, branch string, timestamp time.Time, text string) string {
	return fmt.Sprintf(`{"type":%q,"cwd":%q,"gitBranch":%q,"timestamp":%q,"message":{"content":%q}}`, kind, cwd, branch, timestamp.UTC().Format(time.RFC3339Nano), text)
}

func writeJSONL(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}
func writeExecutable(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}
func read(t *testing.T, path string) string {
	t.Helper()
	value, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(value)
}
func waitRead(t *testing.T, path string) string {
	t.Helper()
	for range 100 {
		if value, err := os.ReadFile(path); err == nil {
			return string(value)
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
	return ""
}
func assertContains(t *testing.T, value, expected string) {
	t.Helper()
	if !strings.Contains(value, expected) {
		t.Fatalf("missing %q in:\n%s", expected, value)
	}
}
func env(home, bin string, extra map[string]string) []string {
	values := append(os.Environ(), "HOME="+home, "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	for key, value := range extra {
		values = append(values, key+"="+value)
	}
	return values
}
func run(t *testing.T, binary string, args, environment []string) string {
	t.Helper()
	cmd := exec.Command(binary, args...)
	cmd.Env = environment
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %v\n%s", args, err, output)
	}
	return string(output)
}
