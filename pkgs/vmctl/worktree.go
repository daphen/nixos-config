package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func runWorktree(a app, ticket, raw string, scriptTag bool) error {
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
	existing, agentConn, err := lookupWorktreeSession(sock, ticket)
	if err != nil {
		return err
	}
	defer agentConn.Close()
	if existing != nil {
		if existing.Profile != "lovable-worker" {
			return fmt.Errorf("session '%s' has profile '%s', expected 'lovable-worker'", ticket, existing.Profile)
		}
		if err := validateTicketCheckout(a, ticket, existing.Cwd); err != nil {
			return fmt.Errorf("refusing session '%s': %w; stop or rename that session explicitly", ticket, err)
		}
		vmwt = existing.Cwd
		worktreeSay(a, "registered checkout: "+vmwt)
	} else {
		branch := "daphen/" + ticket
		worktreeSay(a, "worktree "+vmwt+" on "+branch+" …")
		if _, err := worktreeSSHResult(a, "export PATH=$HOME/.nix-profile/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH\n"+
			"cd '"+repo+"'\n"+
			"if [ -d '"+vmwt+"' ]; then echo '  exists — reusing'\n"+
			"else git fetch --quiet origin main 2>/dev/null || true; git worktree add '"+vmwt+"' -b '"+branch+"' origin/main 2>&1 | tail -1; fi"); err != nil {
			return fmt.Errorf("remote worktree setup failed: %w", err)
		}
	}
	mirror := worktreeMirror(a, ticket, vmwt)

	worktreeSay(a, "boot devenv wt in tmux session wt-"+ticket+" …")
	boot := "export PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH\n" +
		"if tmux has-session -t 'wt-" + ticket + "' 2>/dev/null; then " +
		"[ \"$(tmux display-message -p -t 'wt-" + ticket + "' '#{session_path}')\" = '" + vmwt + "' ] || { echo 'tmux wt-" + ticket + " belongs to another checkout' >&2; exit 19; }; " +
		"echo '  tmux wt-" + ticket + " already running'\n" +
		"else tmux new-session -d -s 'wt-" + ticket + "' -c '" + vmwt + "' " +
		"'export PATH=$HOME/src/lovable/bin:$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH; nix develop ./nix-config --impure -c ./bin/devenv wt --no-meticulous 2>&1 | tee ~/wt-" + ticket + ".log'; " +
		"echo '  started (logs: ~/wt-" + ticket + ".log on the VM, or tmux attach -t wt-" + ticket + ")'; fi"
	if text, err := worktreeSSHResult(a, boot); err != nil {
		return fmt.Errorf("remote dev startup failed for %s: %s", vmwt, strings.TrimSpace(text))
	}

	worktreeSay(a, "local worktree + sync via vm-sync …")
	syncArgs := []string{raw}
	if vmwt != repo+"-"+ticket {
		syncArgs = []string{"--remote-cwd", vmwt, raw}
	}
	text, syncErr := a.combined(filepath.Join(a.home, ".local", "bin", "vm-sync"), syncArgs...)
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if line != "" {
			fmt.Fprintln(a.out, "  "+line)
		}
	}
	mirrorErr := syncErr
	if mirrorErr == nil {
		mirrorErr = verifyWorktreeMirror(a, vmwt, mirror)
	}
	if mirrorErr == nil {
		worktreeSay(a, "mirror current and dependencies ready: "+mirror)
	} else {
		worktreeSay(a, "✗ mirror not current or dependencies not ready: "+mirrorErr.Error())
		worktreeSay(a, "  retry: vm-sync "+strings.Join(syncArgs, " "))
		if existing == nil {
			worktreeSay(a, "new agent was not spawned; VM runtime was left running")
			return silentError{}
		}
	}

	worktreeSay(a, "playwright override (.pi/mcp.json) on the box …")
	if _, err := worktreeSSHResult(a, playwrightCommand(vmwt)); err != nil {
		worktreeSay(a, "  ✗ playwright override failed (non-fatal)")
	}

	seed := "/skill:plan-ticket " + strings.ToUpper(raw)
	worktreeSay(a, "agent context at "+vmwt+" …")
	if err := finishWorktreeAgent(agentConn, existing, ticket, vmwt, seed, a.out); err != nil {
		return err
	}
	worktreeSay(a, "agent ready: select '"+ticket+"' in the rail")
	if mirrorErr != nil {
		if !scriptTag {
			worktreeSay(a, "agent context was preserved; HTTP readiness was not attempted")
			return silentError{}
		}
		worktreeSay(a, "routing the registered runtime despite the independent mirror failure")
	}

	ports, err := discoverWorktreePorts(a, vmwt)
	if err != nil {
		return devURLFailure(a, ticket, "runtime configuration", err)
	}
	if err := ensureWorktreeTunnel(a, ticket, ports, scriptTag); err != nil {
		return devURLFailure(a, ticket, "loopback forwarding", err)
	}
	if err := awaitWorktreeHTTP(ports, scriptTag); err != nil {
		return devURLFailure(a, ticket, "laptop HTTP readiness", err)
	}
	worktreeSay(a, fmt.Sprintf("HTTP ready — testable URL: http://localhost:%d/ (API http://127.0.0.1:%d/health)", ports.web, ports.api))
	worktreeSay(a, "teardown when explicitly finished: vm-wt --teardown "+strings.ToUpper(ticket))
	return nil
}

type worktreePorts struct {
	web, api int
}

func lookupWorktreeSession(path, name string) (*worktreeSession, net.Conn, error) {
	conn, err := net.DialTimeout("unix", path, 8*time.Second)
	if err != nil {
		return nil, nil, err
	}
	_ = conn.SetReadDeadline(time.Now().Add(8 * time.Second))
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	var roster struct {
		Sessions []worktreeSession `json:"sessions"`
	}
	if err := json.Unmarshal(line, &roster); err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	for _, session := range roster.Sessions {
		if session.Name == name {
			return &session, conn, nil
		}
	}
	return nil, conn, nil
}

func validateTicketCheckout(a app, ticket, cwd string) error {
	standard := "/home/" + a.user + "/src/lovable-" + ticket
	if cwd == standard {
		return nil
	}
	if _, _, _, err := explicitSyncPaths(a, ticket, cwd); err != nil {
		return fmt.Errorf("registered cwd %q does not match %s", cwd, strings.ToUpper(ticket))
	}
	return nil
}

func worktreeMirror(a app, ticket, cwd string) string {
	if cwd == "/home/"+a.user+"/src/lovable-"+ticket {
		return filepath.Join(a.home, "work", "lovable.daphen-"+ticket)
	}
	return filepath.Join(a.home, "work", filepath.Base(cwd))
}

func discoverWorktreePorts(a app, cwd string) (worktreePorts, error) {
	script := "set -- '" + cwd + "'/.devenv/state/process-compose-wt-*.yaml\n" +
		"[ -f \"$1\" ] || { echo 'no generated process-compose configuration' >&2; exit 1; }\n" +
		"[ \"$#\" -eq 1 ] || { echo 'multiple generated process-compose configurations' >&2; exit 1; }\n" +
		"printf '%s\\n---VMCTL-CONFIG---\\n' \"$1\"; cat \"$1\""
	text, err := worktreeSSHResult(a, script)
	if err != nil {
		return worktreePorts{}, fmt.Errorf("%s", strings.TrimSpace(text))
	}
	parts := strings.SplitN(text, "\n---VMCTL-CONFIG---\n", 2)
	if len(parts) != 2 {
		return worktreePorts{}, fmt.Errorf("generated process configuration could not be read")
	}
	webMatch := regexp.MustCompile(`(?m)^\s*-?\s*"?WEB_PORT=([0-9]+)"?\s*$`).FindStringSubmatch(parts[1])
	apiMatch := regexp.MustCompile(`(?m)^\s*-?\s*"?VITE_GO_API_BASE_URL=http://127\.0\.0\.1:([0-9]+)"?\s*$`).FindStringSubmatch(parts[1])
	if len(webMatch) != 2 || len(apiMatch) != 2 {
		return worktreePorts{}, fmt.Errorf("%s does not declare WEB_PORT and loopback VITE_GO_API_BASE_URL", strings.TrimSpace(parts[0]))
	}
	web, webErr := strconv.Atoi(webMatch[1])
	api, apiErr := strconv.Atoi(apiMatch[1])
	if webErr != nil || apiErr != nil || web < 1 || web > 65535 || api < 1 || api > 65535 || web == api {
		return worktreePorts{}, fmt.Errorf("invalid web/API ports in %s", strings.TrimSpace(parts[0]))
	}
	worktreeSay(a, fmt.Sprintf("runtime ports from %s: web %d, API %d", strings.TrimSpace(parts[0]), web, api))
	return worktreePorts{web: web, api: api}, nil
}

func ensureWorktreeTunnel(a app, ticket string, ports worktreePorts, scriptTag bool) error {
	unit := ticket + "-dev-tunnel.service"
	forwards := []int{ports.web, ports.api}
	if scriptTag {
		forwards = append(forwards, 8001)
	}
	load := exec.Command("systemctl", "--user", "show", "-p", "LoadState", "--value", unit)
	loaded, _ := load.Output()
	if strings.TrimSpace(string(loaded)) == "loaded" {
		value, err := exec.Command("systemctl", "--user", "show", "-p", "ExecStart", "--value", unit).Output()
		if err != nil {
			return fmt.Errorf("cannot inspect owned unit %s", unit)
		}
		execStart := string(value)
		destination := a.user + "@" + a.host
		fields := strings.Fields(strings.ReplaceAll(execStart, `"`, ""))
		forwardCount, unsafeForward := 0, false
		for _, field := range fields {
			if field == "-L" {
				forwardCount++
			}
			if field == "-R" || field == "-D" {
				unsafeForward = true
			}
		}
		matches := forwardCount == len(forwards) && !unsafeForward && strings.Contains(execStart, destination)
		for _, port := range forwards {
			matches = matches && strings.Contains(execStart, fmt.Sprintf("127.0.0.1:%d:127.0.0.1:%d", port, port))
		}
		if !matches {
			return fmt.Errorf("owned unit %s exists with different forwarding; inspect it, then use vm-wt --teardown %s only if it is obsolete", unit, strings.ToUpper(ticket))
		}
		if exec.Command("systemctl", "--user", "is-active", "--quiet", unit).Run() == nil {
			worktreeSay(a, "reusing owned loopback tunnel "+unit)
			return nil
		}
		if err := exec.Command("systemctl", "--user", "start", unit).Run(); err != nil {
			return fmt.Errorf("matching unit %s could not be started: %w", unit, err)
		}
		worktreeSay(a, "restarted owned loopback tunnel "+unit)
		return nil
	}
	for _, port := range forwards {
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			owner, _ := exec.Command("ss", "-ltnp", fmt.Sprintf("sport = :%d", port)).CombinedOutput()
			return fmt.Errorf("local loopback port %d is already in use by %s", port, strings.TrimSpace(string(owner)))
		}
		_ = listener.Close()
	}
	ssh := "/run/current-system/sw/bin/ssh"
	args := []string{"--user", "--unit=" + strings.TrimSuffix(unit, ".service"), "--collect", "--property=Restart=on-failure", "--property=RestartSec=2s", ssh,
		"-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "StrictHostKeyChecking=yes"}
	for _, port := range forwards {
		args = append(args, "-L", fmt.Sprintf("127.0.0.1:%d:127.0.0.1:%d", port, port))
	}
	args = append(args, a.user+"@"+a.host)
	if text, err := exec.Command("systemd-run", args...).CombinedOutput(); err != nil {
		return fmt.Errorf("could not start %s: %s", unit, strings.TrimSpace(string(text)))
	}
	worktreeSay(a, "started persistent loopback tunnel "+unit)
	return nil
}

func awaitWorktreeHTTP(ports worktreePorts, scriptTag bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	client := &http.Client{Timeout: 5 * time.Second}
	urls := []string{fmt.Sprintf("http://127.0.0.1:%d/health", ports.api), fmt.Sprintf("http://localhost:%d/", ports.web)}
	if scriptTag {
		urls = append(urls, "http://127.0.0.1:8001/lovable.js")
	}
	get := func(url string) (*http.Response, error) {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		return client.Do(request)
	}
	for {
		allReady := true
		for _, url := range urls {
			response, err := get(url)
			if err != nil {
				allReady = false
				continue
			}
			body, readErr := io.ReadAll(io.LimitReader(response.Body, 2<<20))
			_ = response.Body.Close()
			if readErr != nil {
				allReady = false
				continue
			}
			if response.StatusCode != http.StatusOK {
				return fmt.Errorf("%s returned HTTP %d", url, response.StatusCode)
			}
			if url == urls[1] {
				asset := worktreeScriptAsset(body)
				if asset == "" {
					return fmt.Errorf("%s returned no root-relative script or modulepreload asset", url)
				}
				assetURL := fmt.Sprintf("http://localhost:%d%s", ports.web, asset)
				assetResponse, assetErr := get(assetURL)
				if assetErr != nil {
					return fmt.Errorf("client asset %s failed: %w", assetURL, assetErr)
				}
				_ = assetResponse.Body.Close()
				if assetResponse.StatusCode != http.StatusOK {
					return fmt.Errorf("client asset %s returned HTTP %d", assetURL, assetResponse.StatusCode)
				}
			}
		}
		if allReady {
			return nil
		}
		if ctx.Err() != nil {
			return fmt.Errorf("%s and %s did not become reachable within 45s", urls[1], urls[0])
		}
		select {
		case <-time.After(time.Second):
		case <-ctx.Done():
			return fmt.Errorf("%s and %s did not become reachable within 45s", urls[1], urls[0])
		}
	}
}

func worktreeScriptAsset(body []byte) string {
	if match := regexp.MustCompile(`(?is)<script\b[^>]*\bsrc=["'](/[^"']+)["']`).FindSubmatch(body); len(match) == 2 {
		return string(match[1])
	}
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`(?is)<link\b[^>]*\brel=["']modulepreload["'][^>]*\bhref=["'](/[^"']+)["']`),
		regexp.MustCompile(`(?is)<link\b[^>]*\bhref=["'](/[^"']+)["'][^>]*\brel=["']modulepreload["']`),
	}
	for _, pattern := range patterns {
		if match := pattern.FindSubmatch(body); len(match) == 2 {
			return string(match[1])
		}
	}
	return ""
}

func devURLFailure(a app, ticket, stage string, err error) error {
	worktreeSay(a, "✗ HTTP not ready ("+stage+"): "+err.Error())
	worktreeSay(a, "agent context was preserved; retry the canonical check with vm-wt "+strings.ToUpper(ticket))
	return silentError{}
}

func teardownWorktreeTunnel(a app, ticket string) error {
	unit := ticket + "-dev-tunnel.service"
	if err := exec.Command("systemctl", "--user", "stop", unit).Run(); err != nil {
		return fmt.Errorf("could not stop %s: %w", unit, err)
	}
	worktreeSay(a, "stopped "+unit+"; agent, mirror, and remote dev slice were left running")
	return nil
}

func worktreeSay(a app, text string) {
	fmt.Fprintf(a.out, "\x1b[36m[vm-wt]\x1b[0m %s\n", text)
}

func worktreeSSHResult(a app, script string) (string, error) {
	return a.combined("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", a.user+"@"+a.host, script)
}

func worktreeSSHOutput(a app, script string) (string, error) {
	return a.output("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", a.user+"@"+a.host, script)
}

func verifyWorktreeMirror(a app, vmwt, mirror string) error {
	if !pathExists(filepath.Join(mirror, ".git")) {
		return fmt.Errorf("%s is not a git checkout", mirror)
	}
	local, err := a.output("git", "-C", mirror, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("cannot read local mirror head: %w", err)
	}
	remote, err := worktreeSSHOutput(a, "git -C '"+vmwt+"' rev-parse HEAD")
	if err != nil {
		return fmt.Errorf("cannot read registered VM checkout head: %w", err)
	}
	local, remote = strings.TrimSpace(local), strings.TrimSpace(remote)
	if local != remote {
		return fmt.Errorf("head mismatch: mirror %s, registered VM checkout %s", prefix(local, 11), prefix(remote, 11))
	}
	return nil
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
	Cwd     string `json:"cwd"`
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

func finishWorktreeAgent(conn net.Conn, existing *worktreeSession, name, cwd, seed string, out io.Writer) error {
	if existing != nil {
		request := entriesMessage{"get_entries", name}
		if err := writeSocketJSON(conn, request); err != nil {
			return err
		}
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
		return nil
	}
	request := spawnMessage{"spawn", name, cwd, "lovable-worker", seed}
	if err := writeSocketJSON(conn, request); err != nil {
		return err
	}
	_ = conn.SetReadDeadline(time.Now().Add(8 * time.Second))
	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		var message struct {
			Type     string            `json:"type"`
			Session  string            `json:"session"`
			Error    string            `json:"error"`
			Sessions []worktreeSession `json:"sessions"`
		}
		if json.Unmarshal(scanner.Bytes(), &message) != nil {
			continue
		}
		if message.Type == "error" && (message.Session == "" || message.Session == name) {
			return fmt.Errorf("agent spawn failed: %s", message.Error)
		}
		for _, session := range message.Sessions {
			if session.Name == name && session.Cwd == cwd && session.Profile == "lovable-worker" {
				fmt.Fprintf(out, "  spawned '%s' with the plan seed\n", name)
				return nil
			}
		}
	}
	return fmt.Errorf("agent spawn was not acknowledged within 8s")
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
