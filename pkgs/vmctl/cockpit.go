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
	a             app
	restart       bool
	port          string
	runtime, sock string
	marker        string
	ai            string
	ssh           []string
	localHash     string
	wasRunning    bool
}

func runCockpit(a app, restart bool) error {
	runtime := envDefault("XDG_RUNTIME_DIR", "/tmp")
	c := cockpitState{
		a: a, restart: restart,
		port:    envFallback("COCKPIT_VM_AGENTD_PORT", "HEIDR_VM_AGENTD_PORT", "17840"),
		runtime: runtime, sock: filepath.Join(runtime, "agentd-work.sock"),
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
	if err := c.checkPiSkew(); err != nil {
		return err
	}
	if err := c.syncBundle(); err != nil {
		return err
	}
	key := shellOutput(c.bestOutput(nil, "fish", "-c", "source ~/.config/fish/secrets.fish; echo -n $OPENAI_API_KEY"))
	if key == "" {
		c.say("  ⚠ no OPENAI_API_KEY — pi will not start")
	}
	slack := shellOutput(c.bestOutput(nil, "op", "read", "op://Private/Slack MCP/text"))
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

func (c cockpitState) checkPiSkew() error {
	local := firstLine(c.bestOutput(nil, "pi", "--version"))
	remote := firstLine(c.bestSSHOutput("export PATH=$HOME/.npm-global/bin:$PATH; pi --version 2>/dev/null | head -1"))
	if local != "" && remote != "" && local != remote {
		c.say("WARNING: pi version skew — local " + local + ", VM " + remote + " (behaviour here does not predict the VM)")
	}
	return nil
}

func (c *cockpitState) syncBundle() error {
	hash, err := bundleHash(c.ai)
	if err != nil {
		return err
	}
	c.localHash = hash
	remote := shellOutput(c.remoteBundleHash())
	c.wasRunning = shellOutput(c.bestSSHOutput("pgrep -x agentd >/dev/null && echo yes || echo no")) == "yes"
	if remote == hash {
		c.say("role bundle current (" + hash + ")")
		_ = os.Remove(c.marker)
		return nil
	}
	c.say("role bundle differs — syncing versioned resources …")
	if err := c.copyBundle(); err != nil {
		return c.bundleFailure("")
	}
	verified := shellOutput(c.remoteBundleHash())
	if verified != hash {
		return c.bundleFailure(" (local " + hash + ", remote " + emptyAs(verified, "missing") + ")")
	}
	if c.wasRunning {
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
		if isDir(source) {
			if err := c.runSSH("mkdir -p $HOME/.pi/agent/'" + rel + "'"); err != nil {
				return err
			}
			if err := c.rsync(true, source+"/", c.a.user+"@"+c.a.host+":.pi/agent/"+rel+"/"); err != nil {
				return err
			}
		} else {
			if err := c.runSSH("mkdir -p $HOME/.pi/agent/'" + filepath.ToSlash(filepath.Dir(rel)) + "'"); err != nil {
				return err
			}
			if err := c.rsync(false, source, c.a.user+"@"+c.a.host+":.pi/agent/"+rel); err != nil {
				return err
			}
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
`, restart, c.keyringPassword(), key, slack, c.port, c.port)
	cmd := exec.Command(c.ssh[0], append(c.ssh[1:], script)...)
	text, err := cmd.CombinedOutput()
	for _, line := range strings.Split(strings.TrimSuffix(string(text), "\n"), "\n") {
		if line != "" && !strings.HasPrefix(strings.ToLower(line), "warning: permanently") {
			fmt.Fprintln(c.a.out, line)
		}
	}
	return err
}

func (c cockpitState) keyringPassword() string {
	return envFallback("COCKPIT_KEYRING_PW", "HEIDR_KEYRING_PW", "heidr-vm")
}

func (c cockpitState) ensureTunnel() error {
	if isSocket(c.sock) && healthySocket(c.sock) {
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
	for i := 0; i < 8 && !isSocket(c.sock); i++ {
		time.Sleep(time.Second)
	}
	if !isSocket(c.sock) {
		c.say("  ✗ tunnel failed")
		return silentError{}
	}
	c.say("  up ✓")
	return nil
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
	cmd := exec.Command(c.ssh[0], append(c.ssh[1:], script)...)
	cmd.Stderr = io.Discard
	out, _ := cmd.Output()
	return string(out)
}

func (c cockpitState) bestOutput(env []string, name string, args ...string) string {
	cmd := exec.Command(name, args...)
	cmd.Env, cmd.Stderr = commandEnv(env), io.Discard
	out, _ := cmd.Output()
	return string(out)
}

func bundleHash(root string) (string, error) {
	var files []string
	for _, rel := range cockpitRoleFiles {
		path := filepath.Join(root, filepath.FromSlash(rel))
		info, err := os.Stat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		if !info.IsDir() {
			files = append(files, path)
			continue
		}
		err = filepath.Walk(path, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			target, statErr := os.Stat(path)
			if statErr != nil {
				return statErr
			}
			if target.Mode().IsRegular() {
				files = append(files, path)
			}
			return nil
		})
		if err != nil {
			return "", err
		}
	}
	sort.Slice(files, func(i, j int) bool { return relativeSlash(root, files[i]) < relativeSlash(root, files[j]) })
	h := sha256.New()
	for _, path := range files {
		data, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		_, _ = h.Write([]byte(relativeSlash(root, path)))
		_, _ = h.Write([]byte{0})
		sum := sha256.Sum256(data)
		_, _ = h.Write(sum[:])
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func relativeSlash(root, path string) string {
	rel, _ := filepath.Rel(root, path)
	return filepath.ToSlash(rel)
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

func firstLine(value string) string {
	if i := strings.IndexByte(value, '\n'); i >= 0 {
		return value[:i]
	}
	return value
}

func shellOutput(value string) string { return strings.TrimRight(value, "\n") }

func emptyAs(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
