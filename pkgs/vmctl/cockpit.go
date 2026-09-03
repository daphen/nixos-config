package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var cockpitRoleFiles = []string{
	"instructions.md",
	"roles", "prompts/plan-ticket.md", "prompts/review-pr.md",
	"pi-extensions/role-policy", "pi-extensions/agents", "pi-extensions/ask", "pi-extensions/user-bash", "pi-extensions/tool-compress",
	"skills/i-have-adhd", "skills/notes", "skills/cycle", "skills/daily", "skills/standup",
	"skills/plan-ticket", "skills/watch-pr", "skills/review-pr", "skills/handoff",
}

var remoteHashProgram = `import hashlib, pathlib, sys
root = pathlib.Path.home() / '.pi' / 'agent'
files = []
for rel in sys.argv[1:]:
    target = root / rel
    if target.is_dir(): files.extend(p for p in target.rglob('*') if p.is_file())
    elif target.is_file(): files.append(target)
h = hashlib.sha256()
for p in sorted(files, key=lambda item: str(item.relative_to(root))):
    h.update(str(p.relative_to(root)).encode() + b'\0')
    h.update(hashlib.sha256(p.read_bytes()).digest())
print(h.hexdigest())
`

type cockpitState struct {
	a       app
	restart bool
	port    string
	sock    string
	marker  string
	ai      string
	ssh     []string
}

func runCockpit(a app, restart bool) error {
	runtime := envDefault("XDG_RUNTIME_DIR", "/tmp")
	c := cockpitState{
		a: a, restart: restart,
		port:   envFallback("COCKPIT_VM_AGENTD_PORT", "HEIDR_VM_AGENTD_PORT", "17840"),
		sock:   filepath.Join(runtime, "agentd-work.sock"),
		marker: filepath.Join(runtime, "cockpit-role-bundle-work.restart-required"),
		ai:     filepath.Join(a.home, "nixos", "dotfiles", "ai"),
		ssh:    []string{"ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=25", a.user + "@" + a.host},
	}
	legacy := filepath.Join(runtime, "heidr-role-bundle-work.restart-required")
	if _, err := os.Stat(legacy); err == nil {
		if err := os.Rename(legacy, c.marker); err != nil {
			return err
		}
	}
	if !isDir(filepath.Join(c.ai, "roles")) {
		c.say("sync failed, do not spawn ticket sessions: " + filepath.Join(c.ai, "roles") + " missing")
		return silentError{}
	}
	c.checkPiSkew()
	if err := c.syncBundle(); err != nil {
		return err
	}
	key, _ := c.a.output("fish", "-c", "source ~/.config/fish/secrets.fish; echo -n $OPENAI_API_KEY")
	key = strings.TrimRight(key, "\n")
	if key == "" {
		c.say("  ⚠ no OPENAI_API_KEY — pi will not start")
	}
	slack, _ := c.a.output("op", "read", "op://Private/Slack MCP/text")
	slack = strings.TrimRight(slack, "\n")
	if slack == "" {
		c.say("  (no Slack secret — run 'op signin' if you want the slack mcp)")
	}
	if err := c.startAgentd(key, slack); err != nil {
		return err
	}
	if restart {
		_ = os.Remove(c.marker)
	}
	if err := c.ensureTunnel(); err != nil {
		return err
	}
	c.say("done — launch Cockpit (./run-qs.sh picks up lovable + work automatically)")
	return nil
}

func (c cockpitState) say(text string) {
	fmt.Fprintf(c.a.out, "\x1b[36m[vm-cockpit]\x1b[0m %s\n", text)
}

func (c cockpitState) checkPiSkew() {
	local, _ := c.a.output("pi", "--version")
	remote := c.bestSSHOutput("export PATH=$HOME/.npm-global/bin:$PATH; pi --version 2>/dev/null | head -1")
	local, _, _ = strings.Cut(local, "\n")
	remote, _, _ = strings.Cut(remote, "\n")
	if local != "" && remote != "" && local != remote {
		c.say("WARNING: pi version skew — local " + local + ", VM " + remote + " (behaviour here does not predict the VM)")
	}
}

func (c cockpitState) syncBundle() error {
	hash, err := bundleHash(c.ai)
	if err != nil {
		return err
	}
	remote := strings.TrimRight(c.remoteBundleHash(), "\n")
	wasRunning := strings.TrimRight(c.bestSSHOutput("pgrep -x agentd >/dev/null && echo yes || echo no"), "\n") == "yes"
	if remote == hash {
		c.say("role bundle current (" + hash + ")")
		_ = os.Remove(c.marker)
		return nil
	}
	c.say("role bundle differs — syncing versioned resources …")
	if err := c.copyBundle(); err != nil {
		return c.bundleFailure("")
	}
	verified := strings.TrimRight(c.remoteBundleHash(), "\n")
	if verified != hash {
		if verified == "" {
			verified = "missing"
		}
		return c.bundleFailure(" (local " + hash + ", remote " + verified + ")")
	}
	if wasRunning {
		if err := touch(c.marker); err != nil {
			return err
		}
		c.say("role bundle updated, agentd restart required (" + hash + ")")
	} else {
		_ = os.Remove(c.marker)
		c.say("role bundle updated and verified (" + hash + "); agentd will start with it")
	}
	return nil
}

func (c cockpitState) copyBundle() error {
	for _, rel := range cockpitRoleFiles {
		source := filepath.Join(c.ai, filepath.FromSlash(rel))
		directory := isDir(source)
		remoteDir, suffix := filepath.ToSlash(filepath.Dir(rel)), ""
		if directory {
			remoteDir, suffix = rel, "/"
		}
		if err := c.runSSH("mkdir -p $HOME/.pi/agent/'" + remoteDir + "'"); err != nil {
			return err
		}
		if err := c.rsync(directory, source+suffix, c.a.user+"@"+c.a.host+":.pi/agent/"+rel+suffix); err != nil {
			return err
		}
	}
	return c.rsync(false, filepath.Join(c.ai, "instructions.md"), c.a.user+"@"+c.a.host+":.pi/agent/AGENTS.md")
}

func (c cockpitState) rsync(delete bool, source, target string) error {
	args := []string{"-az"}
	if delete {
		args = append(args, "--delete")
	}
	args = append(args, "-e", "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=25", source, target)
	cmd := exec.Command("rsync", args...)
	cmd.Stdout, cmd.Stderr = c.a.out, c.a.err
	return cmd.Run()
}

func (c cockpitState) bundleFailure(detail string) error {
	c.say("sync failed, do not spawn ticket sessions" + detail)
	if err := touch(c.marker); err != nil {
		return err
	}
	return silentError{}
}

func (c cockpitState) startAgentd(key, slack string) error {
	c.say("agentd on " + c.a.vm + " (dbus + unlocked keyring) …")
	restart := "no"
	if c.restart {
		restart = "yes"
	}
	script := fmt.Sprintf(`
  export PATH=$HOME/.nix-profile/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH
  export XDG_DATA_DIRS="$HOME/.nix-profile/share:/run/current-system/sw/share:/usr/local/share:/usr/share"
  if [ '%s' = yes ] && pgrep -x agentd >/dev/null 2>&1; then
    echo "  restart requested — stopping agentd (pid $(pgrep -x agentd | tr '\n' ' '))"
    kill -TERM "$(pgrep -x agentd)"
    for _ in $(seq 1 30); do pgrep -x agentd >/dev/null 2>&1 || break; sleep 1; done
    pgrep -x agentd >/dev/null 2>&1 && { echo '  agentd did not stop'; exit 1; }
  fi
  if ! pgrep -x agentd >/dev/null 2>&1; then
    _cfg=$(ls /nix/store/*dbus-1*/share/dbus-1/session.conf 2>/dev/null | head -1)
    export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --config-file="$_cfg" --print-address --fork 2>/dev/null)
    mkdir -p ~/.local/share/keyrings
    eval "$(printf %%s '%s' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)" || true
    setsid env OPENAI_API_KEY='%s' SLACK_MCP_CLIENT_SECRET='%s' \
      COCKPIT_SLICE_REAP_HOOK=$HOME/.local/bin/vm-slice-reaper \
      DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" XDG_DATA_DIRS="$XDG_DATA_DIRS" \
      PATH="$PATH" $HOME/.local/bin/agentd --scope work --repo $HOME/src/lovable \
      --listen 127.0.0.1:%s >$HOME/agentd.log 2>&1 </dev/null &
    sleep 4
  else echo "  already running (pid $(pgrep -x agentd | tr '\n' ' '), up $(ps -o etime= -p $(pgrep -x agentd | head -1) 2>/dev/null | tr -d ' '))"; fi
  (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q :%s && echo '  listening ✓' || tail -4 $HOME/agentd.log
`, restart, envFallback("COCKPIT_KEYRING_PW", "HEIDR_KEYRING_PW", "heidr-vm"), key, slack, c.port, c.port)
	cmd := exec.Command(c.ssh[0], append(c.ssh[1:], script)...)
	text, err := cmd.CombinedOutput()
	for _, line := range strings.Split(strings.TrimSuffix(string(text), "\n"), "\n") {
		if line != "" && !strings.HasPrefix(strings.ToLower(line), "warning: permanently") {
			fmt.Fprintln(c.a.out, line)
		}
	}
	return err
}

func (c cockpitState) ensureTunnel() error {
	if healthySocket(c.sock) {
		c.say("tunnel already healthy → " + c.sock)
		return nil
	}
	c.say("tunnel " + c.sock + " → " + c.a.vm + ":" + c.port + " …")
	_ = os.Remove(c.sock)
	args := []string{"ssh", "-N", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-L", c.sock + ":127.0.0.1:" + c.port, c.a.user + "@" + c.a.host}
	cmd := exec.Command("setsid", args...)
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	if err := cmd.Start(); err != nil {
		return err
	}
	_ = cmd.Process.Release()
	for i := 0; i <= 8; i++ {
		if isSocket(c.sock) {
			c.say("  up ✓")
			return nil
		}
		if i < 8 {
			time.Sleep(time.Second)
		}
	}
	c.say("  ✗ tunnel failed")
	return silentError{}
}

func (c cockpitState) remoteBundleHash() string {
	args := append(append([]string{}, c.ssh[1:]...), "python3", "-")
	args = append(args, cockpitRoleFiles...)
	cmd := exec.Command(c.ssh[0], args...)
	cmd.Stdin, cmd.Stderr = strings.NewReader(remoteHashProgram), io.Discard
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return string(out)
}

func (c cockpitState) runSSH(script string) error {
	cmd := exec.Command(c.ssh[0], append(c.ssh[1:], script)...)
	cmd.Stdout, cmd.Stderr = c.a.out, c.a.err
	return cmd.Run()
}

func (c cockpitState) bestSSHOutput(script string) string {
	out, _ := c.a.output(c.ssh[0], append(c.ssh[1:], script)...)
	return out
}

func bundleHash(root string) (string, error) {
	var files []string
	for _, rel := range cockpitRoleFiles {
		rootPath := filepath.Join(root, filepath.FromSlash(rel))
		err := filepath.Walk(rootPath, func(path string, info os.FileInfo, err error) error {
			if os.IsNotExist(err) && path == rootPath {
				return nil
			}
			if err != nil {
				return err
			}
			regular := info.Mode().IsRegular()
			if info.Mode()&os.ModeSymlink != 0 {
				target, statErr := os.Stat(path)
				if statErr != nil {
					return statErr
				}
				regular = target.Mode().IsRegular()
			}
			if regular {
				rel, relErr := filepath.Rel(root, path)
				if relErr != nil {
					return relErr
				}
				files = append(files, filepath.ToSlash(rel))
			}
			return nil
		})
		if err != nil {
			return "", err
		}
	}
	sort.Strings(files)
	h := sha256.New()
	for _, rel := range files {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			return "", err
		}
		_, _ = h.Write([]byte(rel))
		_, _ = h.Write([]byte{0})
		sum := sha256.Sum256(data)
		_, _ = h.Write(sum[:])
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func healthySocket(path string) bool {
	conn, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, 64)
	_, err = conn.Read(buf)
	return err == nil
}

func isSocket(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode()&os.ModeSocket != 0
}

func touch(path string) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		return err
	}
	return file.Close()
}
