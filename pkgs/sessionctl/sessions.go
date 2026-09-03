package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const previewTail int64 = 400_000

type event struct {
	Type        string `json:"type"`
	Cwd         string `json:"cwd"`
	GitBranch   string `json:"gitBranch"`
	Timestamp   string `json:"timestamp"`
	CustomTitle string `json:"customTitle"`
	AITitle     string `json:"aiTitle"`
	Message     struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type sessionRow struct{ id, cwd, path, display string }
type transcriptMessage struct{ role, text, timestamp string }

func textContent(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) != nil {
		return ""
	}
	for _, part := range parts {
		if part.Type == "text" {
			return part.Text
		}
	}
	return ""
}

func readEvents(path string, visit func([]byte, event)) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	for {
		raw, readErr := reader.ReadBytes('\n')
		if len(raw) > 0 {
			var item event
			if json.Unmarshal(raw, &item) == nil {
				visit(raw, item)
			}
		}
		if readErr != nil {
			if readErr == io.EOF {
				return nil
			}
			return readErr
		}
	}
}

func scanSession(path string, now time.Time) (sessionRow, bool) {
	var first *event
	var recent []event
	var lastTimestamp, customTitle, aiTitle string
	if readEvents(path, func(raw []byte, item event) {
		if item.Timestamp != "" {
			lastTimestamp = item.Timestamp
		}
		if item.Type == "user" {
			if first == nil {
				copy := item
				first = &copy
			}
			if !bytes.Contains(raw, []byte("tool_result")) {
				recent = append(recent, item)
				if len(recent) > 50 {
					recent = recent[1:]
				}
			}
		}
		if item.Type == "custom-title" && item.CustomTitle != "" {
			customTitle = item.CustomTitle
		}
		if item.Type == "ai-title" && item.AITitle != "" {
			aiTitle = item.AITitle
		}
	}) != nil || first == nil || first.Cwd == "" {
		return sessionRow{}, false
	}
	text := ""
	for i := len(recent) - 1; i >= 0; i-- {
		candidate := strings.TrimSpace(strings.ReplaceAll(textContent(recent[i].Message.Content), "\n", " "))
		if candidate != "" && !strings.HasPrefix(candidate, "<") {
			text = candidate
			break
		}
	}
	if text == "" {
		text = strings.TrimSpace(strings.ReplaceAll(textContent(first.Message.Content), "\n", " "))
	}
	if text == "" {
		return sessionRow{}, false
	}
	text = prefix(text, 120)
	label := sessionLabel(*first, customTitle, aiTitle)
	if len([]rune(label)) > 30 {
		label = prefix(label, 27) + "..."
	}
	if lastTimestamp == "" {
		lastTimestamp = first.Timestamp
	}
	return sessionRow{
		id: filepath.Base(strings.TrimSuffix(path, filepath.Ext(path))), cwd: first.Cwd, path: path,
		display: fmt.Sprintf("%-8s  %-30s  %s", ago(lastTimestamp, now, false), label, text),
	}, true
}

func sessionLabel(first event, customTitle, aiTitle string) string {
	branch := first.GitBranch
	if before, after, ok := strings.Cut(branch, "/"); ok && before != "" {
		branch = after
	}
	worktree := ""
	base := filepath.Base(first.Cwd)
	if strings.HasPrefix(base, "lovable.") {
		worktree = strings.TrimPrefix(base, "lovable.")
		worktree = strings.TrimPrefix(worktree, "daphen-")
		head, rest, found := strings.Cut(worktree, "-")
		if found && head != "review" && rest != "" && rest[0] >= '0' && rest[0] <= '9' {
			worktree = rest
		}
	}
	for _, value := range []string{customTitle, worktree, aiTitle, branch} {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return "-"
}

func ago(raw string, now time.Time, seconds bool) string {
	parsed, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return "-"
	}
	delta := int(now.Sub(parsed).Seconds())
	if seconds && delta < 60 {
		return fmt.Sprintf("%ds ago", delta)
	}
	if delta < 3600 {
		return fmt.Sprintf("%dm ago", delta/60)
	}
	if delta < 86400 {
		return fmt.Sprintf("%dh ago", delta/3600)
	}
	if delta < 604800 {
		return fmt.Sprintf("%dd ago", delta/86400)
	}
	return parsed.Format("Jan 02")
}

func discover(root string) []sessionRow {
	type candidate struct {
		path  string
		mtime time.Time
	}
	var files []candidate
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() && entry.Name() == "subagents" {
			return filepath.SkipDir
		}
		if entry.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		if info, statErr := entry.Info(); statErr == nil {
			files = append(files, candidate{path, info.ModTime()})
		}
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.After(files[j].mtime) })
	now := time.Now().UTC()
	rows := make([]sessionRow, 0, len(files))
	for _, file := range files {
		if row, ok := scanSession(file.path, now); ok {
			rows = append(rows, row)
		}
	}
	return rows
}

func runPicker(idOnly bool, out, errOut io.Writer) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	rows := discover(filepath.Join(home, ".claude", "projects"))
	if len(rows) == 0 {
		fmt.Fprintln(out, "No sessions found")
		time.Sleep(2 * time.Second)
		return silentError{}
	}
	meta, err := os.CreateTemp("", "sessionctl-meta-*")
	if err != nil {
		return err
	}
	defer os.Remove(meta.Name())
	var input strings.Builder
	for i, row := range rows {
		fmt.Fprintf(meta, "%s\t%s\t%s\n", row.id, row.cwd, row.path)
		fmt.Fprintf(&input, "%d\t%s\n", i+1, row.display)
	}
	if err := meta.Close(); err != nil {
		return err
	}
	preview := "sessionctl preview {1} " + shellQuote(meta.Name())
	rename := fmt.Sprintf("ctrl-r:execute(sid=$(sed -n \"{1}p\" %s | cut -f1); %s --id \"$sid\")", shellQuote(meta.Name()), shellQuote(filepath.Join(home, ".config/niri/scripts/claude-rename")))
	args := []string{"--delimiter=\t", "--with-nth=2", "--height=100%", "--reverse", "--border=rounded", "--prompt=  ", "--no-sort", "--preview=" + preview, "--preview-window=down:60%:wrap:follow", "--header=ctrl-r: rename session  •  ctrl-d/u: scroll preview", "--bind=ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up", "--bind=" + rename}
	fzf := exec.Command("fzf", args...)
	fzf.Stdin, fzf.Stderr = strings.NewReader(input.String()), errOut
	selected, runErr := fzf.Output()
	if runErr != nil || len(bytes.TrimSpace(selected)) == 0 {
		return nil
	}
	line, err := strconv.Atoi(strings.SplitN(string(selected), "\t", 2)[0])
	if err != nil || line < 1 || line > len(rows) {
		return nil
	}
	row := rows[line-1]
	if idOnly {
		fmt.Fprintln(out, row.id)
	} else {
		runDetached(row)
	}
	return nil
}

func runPreview(lineRaw, metaPath string, out, errOut io.Writer) error {
	line, err := strconv.Atoi(lineRaw)
	if err != nil || line < 1 {
		return fmt.Errorf("invalid line %q", lineRaw)
	}
	meta, err := os.ReadFile(metaPath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSuffix(string(meta), "\n"), "\n")
	if line > len(lines) {
		return nil
	}
	parts := strings.SplitN(lines[line-1], "\t", 3)
	if len(parts) != 3 {
		return fmt.Errorf("invalid metadata")
	}
	markdown, err := previewMarkdown(parts[0], parts[1], parts[2], time.Now().UTC())
	if err != nil {
		return err
	}
	glow := exec.Command("glow", "-s", "dark", "-w", "0", "-")
	glow.Stdin, glow.Stdout, glow.Stderr = strings.NewReader(markdown), out, errOut
	return glow.Run()
}

func previewMarkdown(id, cwd, path string, now time.Time) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	truncated := info.Size() > previewTail
	reader := bufio.NewReader(file)
	if truncated {
		_, _ = file.Seek(info.Size()-previewTail, io.SeekStart)
		reader = bufio.NewReader(file)
		_, _ = reader.ReadBytes('\n')
	}
	var messages []transcriptMessage
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), int(previewTail)+1)
	for scanner.Scan() {
		var item event
		if json.Unmarshal(scanner.Bytes(), &item) != nil {
			continue
		}
		if item.Type == "user" {
			text := strings.TrimSpace(textContent(item.Message.Content))
			if text != "" && !strings.HasPrefix(text, "<") {
				messages = append(messages, transcriptMessage{"you", text, item.Timestamp})
			}
		} else if item.Type == "assistant" {
			var parts []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}
			_ = json.Unmarshal(item.Message.Content, &parts)
			for _, part := range parts {
				if text := strings.TrimSpace(part.Text); part.Type == "text" && text != "" {
					messages = append(messages, transcriptMessage{"claude", text, item.Timestamp})
					break
				}
			}
		}
	}
	if len(messages) > 25 {
		messages = messages[len(messages)-25:]
	}
	latest := ""
	if len(messages) > 0 {
		latest = messages[len(messages)-1].timestamp
	}
	shortCwd := cwd
	if home, homeErr := os.UserHomeDir(); homeErr == nil && strings.HasPrefix(cwd, home) {
		shortCwd = "~" + strings.TrimPrefix(cwd, home)
	}
	var result strings.Builder
	fmt.Fprintf(&result, "# %s\n`%s…` · %s", shortCwd, prefix(id, 8), previewAgo(latest, now))
	if truncated {
		result.WriteString(" · _older history omitted_")
	}
	result.WriteString("\n\n---\n\n")
	if len(messages) == 0 {
		result.WriteString("_(no messages)_\n")
	}
	for _, message := range messages {
		label := "Claude"
		if message.role == "you" {
			label = "You"
		}
		fmt.Fprintf(&result, "**%s** · %s\n\n", label, previewAgo(message.timestamp, now))
		text := prefix(message.text, 400)
		if message.role == "you" {
			for _, line := range strings.Split(text, "\n") {
				if line == "" {
					result.WriteString(">\n")
				} else {
					fmt.Fprintf(&result, "> %s\n", line)
				}
			}
		} else {
			result.WriteString(text + "\n")
		}
		result.WriteByte('\n')
	}
	return result.String(), nil
}

func previewAgo(raw string, now time.Time) string {
	if raw == "" {
		return ""
	}
	value := ago(raw, now, true)
	if value == "-" {
		return ""
	}
	return value
}

func prefix(value string, length int) string {
	runes := []rune(value)
	if len(runes) <= length {
		return value
	}
	return string(runes[:length])
}

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }
