package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func runWorktree(a app, ticket, raw string) error {
	runtime := envDefault("XDG_RUNTIME_DIR", "/tmp")
	sock := filepath.Join(runtime, "agentd-work.sock")
	if !isSocket(sock) {
		fmt.Fprintf(a.err, "✗ %s missing — run vm-cockpit first\n", sock)
		return silentError{}
	}
	marker := filepath.Join(runtime, "heidr-role-bundle-work.restart-required")
	if pathExists(marker) {
		fmt.Fprintln(a.err, "✗ role bundle updated, agentd restart required — do not spawn ticket sessions")
		return silentError{}
	}

	repo := "/home/" + a.user + "/src/lovable"
	vmwt := repo + "-" + ticket
	mirror := filepath.Join(a.home, "work", "lovable.daphen-"+ticket)
	branch := "daphen/" + ticket

	worktreeSay(a, "worktree "+vmwt+" on "+branch+" …")
	worktreeSSH(a, "export PATH=$HOME/.nix-profile/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH\n"+
		"cd '"+repo+"'\n"+
		"if [ -d '"+vmwt+"' ]; then echo '  exists — reusing'\n"+
		"else git fetch --quiet origin main 2>/dev/null || true; git worktree add '"+vmwt+"' -b '"+branch+"' origin/main 2>&1 | tail -1; fi")

	worktreeSay(a, "boot devenv wt in tmux session wt-"+ticket+" …")
	worktreeSSH(a, "export PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH\n"+
		"if tmux has-session -t 'wt-"+ticket+"' 2>/dev/null; then echo '  tmux wt-"+ticket+" already running'\n"+
		"else tmux new-session -d -s 'wt-"+ticket+"' -c '"+vmwt+"' "+
		"'export PATH=$HOME/src/lovable/bin:$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH; nix develop ./nix-config --impure -c ./bin/devenv wt --no-meticulous 2>&1 | tee ~/wt-"+ticket+".log'; "+
		"echo '  started (logs: ~/wt-"+ticket+".log on the VM, or tmux attach -t wt-"+ticket+")'; fi")

	worktreeSay(a, "local worktree + sync via vm-sync …")
	text, _ := a.combined(filepath.Join(a.home, ".local", "bin", "vm-sync"), raw)
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if line != "" {
			fmt.Fprintln(a.out, "  "+line)
		}
	}
	if pathExists(filepath.Join(mirror, ".git")) {
		worktreeSay(a, "local mirror ready: "+mirror)
	} else {
		worktreeSay(a, "✗✗ NO LOCAL MIRROR — nvim will show no files for this ticket.")
		worktreeSay(a, "   retry with:  vm-sync "+raw)
		worktreeSay(a, "   until it succeeds, this session's diff is only visible on the VM.")
	}
	worktreeDeps(a, mirror)

	worktreeSay(a, "playwright override (.pi/mcp.json) on the box …")
	if _, err := worktreeSSHResult(a, playwrightCommand(vmwt)); err != nil {
		worktreeSay(a, "  ✗ playwright override failed (non-fatal)")
	}

	seed := "/skill:plan-ticket " + strings.ToUpper(raw)
	worktreeSay(a, "spawn rail session '"+ticket+"' at "+vmwt+" (seeded: "+seed+") …")
	if err := worktreeAgent(sock, ticket, vmwt, seed, a.out); err != nil {
		return err
	}
	worktreeSay(a, "done — select '"+ticket+"' in the rail; nvim lands in "+mirror)
	return nil
}

func worktreeSay(a app, text string) {
	fmt.Fprintf(a.out, "\x1b[36m[vm-wt]\x1b[0m %s\n", text)
}

func worktreeSSH(a app, script string) {
	text, _ := worktreeSSHResult(a, script)
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if line != "" && !strings.HasPrefix(strings.ToLower(line), "warning: permanently") {
			fmt.Fprintln(a.out, line)
		}
	}
}

func worktreeSSHResult(a app, script string) (string, error) {
	return a.combined("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", a.user+"@"+a.host, script)
}

func worktreeDeps(a app, mirror string) {
	if !isFile(filepath.Join(mirror, "package.json")) || isDir(filepath.Join(mirror, "node_modules")) {
		return
	}
	worktreeSay(a, "pnpm install (background) for mirror deps …")
	allow := exec.Command("direnv", "allow", ".")
	allow.Dir, allow.Stdout, allow.Stderr = mirror, io.Discard, io.Discard
	if allow.Run() != nil {
		return
	}
	log, err := os.Create(filepath.Join(mirror, ".pnpm-install.log"))
	if err != nil {
		return
	}
	cmd := exec.Command("nohup", "direnv", "exec", mirror, "pnpm", "install", "--frozen-lockfile", "--prefer-offline")
	cmd.Dir, cmd.Stdout, cmd.Stderr = mirror, log, log
	_ = cmd.Start()
	_ = log.Close()
}

func playwrightCommand(vmwt string) string {
	return "mkdir -p '" + vmwt + "/.pi' && cat > '" + vmwt + "/.pi/mcp.json' <<'JSON'\n" + `{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest", "--headless", "--browser", "chromium"],
      "env": { "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1", "PLAYWRIGHT_BROWSERS_PATH": "/nix/store/6n74mm97b8f8gfra77hiz9q4ffiianpy-playwright-browsers" },
      "lifecycle": "lazy"
    }
  }
}
JSON
` + "gd=$(git -C '" + vmwt + "' rev-parse --git-common-dir 2>/dev/null) && mkdir -p \"$gd/info\" && (grep -qx '.pi/' \"$gd/info/exclude\" 2>/dev/null || echo '.pi/' >> \"$gd/info/exclude\")"
}

type worktreeSession struct {
	Name    string `json:"name"`
	Profile string `json:"profile"`
}

type entriesMessage struct {
	Type    string `json:"type"`
	Session string `json:"session"`
}

type promptMessage struct {
	Type    string `json:"type"`
	Session string `json:"session"`
	Message string `json:"message"`
}

type spawnMessage struct {
	Type    string `json:"type"`
	Session string `json:"session"`
	Cwd     string `json:"cwd"`
	Profile string `json:"profile"`
	Prompt  string `json:"prompt"`
}

func worktreeAgent(path, name, cwd, seed string, out io.Writer) error {
	conn, err := net.DialTimeout("unix", path, 8*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(8 * time.Second))
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return err
	}
	var roster struct {
		Sessions []worktreeSession `json:"sessions"`
	}
	if err := json.Unmarshal(line, &roster); err != nil {
		return err
	}
	for _, session := range roster.Sessions {
		if session.Name != name {
			continue
		}
		if session.Profile != "lovable-worker" {
			return fmt.Errorf("session '%s' has profile '%s', expected 'lovable-worker'", name, session.Profile)
		}
		request := entriesMessage{"get_entries", name}
		if err := writeSocketJSON(conn, request); err != nil {
			return err
		}
		time.Sleep(2 * time.Second)
		_ = conn.SetReadDeadline(time.Now().Add(4 * time.Second))
		blob, _ := io.ReadAll(conn)
		if strings.Contains(string(blob), `"type":"text"`) || strings.Contains(string(blob), `"role":"user"`) {
			fmt.Fprintf(out, "  session '%s' already has history — not re-seeding\n", name)
		} else {
			request := promptMessage{"prompt", name, seed}
			if err := writeSocketJSON(conn, request); err != nil {
				return err
			}
			fmt.Fprintf(out, "  session '%s' existed but was empty — seeded\n", name)
		}
		time.Sleep(3 * time.Second)
		return nil
	}
	request := spawnMessage{"spawn", name, cwd, "lovable-worker", seed}
	if err := writeSocketJSON(conn, request); err != nil {
		return err
	}
	fmt.Fprintf(out, "  spawned '%s' with the plan seed\n", name)
	time.Sleep(3 * time.Second)
	return nil
}

func writeSocketJSON(w io.Writer, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = w.Write(data)
	return err
}
