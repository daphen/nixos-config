package main

import (
	"bufio"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestEditorCLIStartsOnceAndForwardsBothSockets(t *testing.T) {
	if path := "/run/user/1451533466/cockpit-editors/cockpit-nvim-remote-editor-integration-remote.sock"; len(path) > 107 {
		t.Fatalf("Unix socket path is %d bytes", len(path))
	}
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	runtime, err := os.MkdirTemp("/tmp", "vml-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(runtime)
	if err := os.MkdirAll(filepath.Join(runtime, "quickshell/by-id/window-1"), 0o700); err != nil {
		t.Fatal(err)
	}
	qs, err := net.Listen("unix", filepath.Join(runtime, "quickshell/by-id/window-1/ipc.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer qs.Close()
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(home, "calls")
	state := filepath.Join(home, "active")
	forwardState := filepath.Join(home, "forwarded-once")
	remoteRuntime, err := os.MkdirTemp("/tmp", "vmr-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(remoteRuntime)
	writeExecutable(t, filepath.Join(bin, "nvim"), `#!/bin/sh
printf 'nvim|%s\n' "$*" >> "$VMCTL_LOG"
case "$*" in
  *foreign*) exit 1 ;;
  *"--server $VMCTL_DESKTOP_RUNTIME/"*) printf '%s\n' "${VMCTL_LOCAL_READY:-2}" ;;
  *) printf '2\n' ;;
esac
`)
	writeExecutable(t, filepath.Join(bin, "ssh"), `#!/bin/sh
printf 'ssh|%s\n' "$*" >> "$VMCTL_LOG"
case " $* " in
  *" test -x "*) test ! -f "$VMCTL_REMOTE_MISSING" ;;
  *"nix-store --add-root"*) rm -f "$VMCTL_REMOTE_MISSING" ;;
  *" sh -s -- "*) while [ "$#" -gt 3 ]; do shift; done; XDG_RUNTIME_DIR="$VMCTL_REMOTE_RUNTIME" PATH="$VMCTL_BIN:$PATH" sh -s -- "$@" ;;
  *) if [ ! -f "$VMCTL_FORWARD_STATE" ]; then touch "$VMCTL_FORWARD_STATE"; sleep .15; exit 1; fi; sleep 30 ;;
esac
`)
	writeExecutable(t, filepath.Join(bin, "systemctl"), `#!/bin/sh
printf 'systemctl|%s\n' "$*" >> "$VMCTL_LOG"
case "$*" in *is-active*) test -f "$VMCTL_STATE";; *" show "*) printf 'Cockpit remote editor demo\n';; *) exit 0;; esac
`)
	writeExecutable(t, filepath.Join(bin, "systemd-run"), `#!/bin/sh
printf 'systemd-run|%s\n' "$*" >> "$VMCTL_LOG"; touch "$VMCTL_STATE"
`)
	writeExecutable(t, filepath.Join(bin, "rm"), "#!/bin/sh\nprintf 'rm|%s\\n' \"$*\" >> \"$VMCTL_LOG\"; exec /run/current-system/sw/bin/rm \"$@\"\n")
	writeExecutable(t, filepath.Join(bin, "ss"), "#!/bin/sh\nexit 0\n")
	for _, name := range []string{"cat", "chmod", "grep", "id", "mkdir", "sh", "sleep", "timeout", "touch"} {
		real, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(real, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	env := append(os.Environ(), "HOME="+home, "PATH="+bin, "XDG_RUNTIME_DIR="+runtime,
		"VMCTL_EDITOR_NVIM="+filepath.Join(bin, "nvim"), "VMCTL_LOG="+log,
		"VMCTL_BIN="+bin, "VMCTL_STATE="+state, "VMCTL_FORWARD_STATE="+forwardState,
		"VMCTL_REMOTE_RUNTIME="+remoteRuntime, "VMCTL_DESKTOP_RUNTIME="+runtime)
	first, firstOut := startEditorCLI(t, env)
	time.Sleep(1400 * time.Millisecond)
	first.Process.Kill()
	time.Sleep(100 * time.Millisecond)
	second, secondOut := startEditorCLI(t, env)
	defer second.Process.Kill()
	want := filepath.Join(runtime, "cockpit-nvim-demo-remote.sock")
	if firstOut != want || secondOut != want {
		t.Fatalf("ready paths = %q, %q; want %q", firstOut, secondOut, want)
	}
	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	text := string(calls)
	if strings.Count(text, "systemd-run|") != 1 || strings.Count(text, " -N -L ") < 3 ||
		strings.Contains(text, "StreamLocalBindUnlink") || strings.Contains(text, "systemctl|--user stop") ||
		!strings.Contains(text, "--setenv=COCKPIT_INSTANCE=demo --setenv=COCKPIT_COCKPIT=1 --setenv=COCKPIT_SCOPE=lovable") {
		t.Fatalf("editor ownership was not preserved:\n%s", text)
	}
	for _, want := range []string{
		"-L " + filepath.Join(runtime, "cockpit-nvim-demo-remote.sock") + ":" + filepath.Join(remoteRuntime, "cockpit-editors/cockpit-nvim-demo-remote.sock"),
		"-R " + filepath.Join(remoteRuntime, "quickshell/by-id/window-1/ipc.sock") + ":" + filepath.Join(runtime, "quickshell/by-id/window-1/ipc.sock"),
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q:\n%s", want, text)
		}
	}

	partial := exec.Command(binary, "editor", "demo", "window-1")
	partial.Env = append(env, "VMCTL_LOCAL_READY=1")
	partialOut, err := partial.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := partial.Start(); err != nil {
		t.Fatal(err)
	}
	line := make(chan string, 1)
	go func() { value, _ := bufio.NewReader(partialOut).ReadString('\n'); line <- value }()
	select {
	case value := <-line:
		t.Fatalf("partial startup reported ready: %q", value)
	case <-time.After(300 * time.Millisecond):
	}
	partial.Process.Kill()
	second.Process.Kill()
	time.Sleep(100 * time.Millisecond)

	parent := exec.Command("sh", "-c", `"$VMCTL_BINARY" editor demo window-1 & echo $!; wait`)
	parent.Env = append(env, "VMCTL_BINARY="+binary)
	parentOut, err := parent.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(parentOut)
	controllerPID, err := strconv.Atoi(strings.TrimSpace(readLine(t, reader)))
	if err != nil {
		t.Fatal(err)
	}
	if ready := strings.TrimSpace(readLine(t, reader)); ready != filepath.Join(runtime, "cockpit-nvim-demo-remote.sock") {
		t.Fatalf("parented ready=%q", ready)
	}
	children, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(controllerPID), "task", strconv.Itoa(controllerPID), "children"))
	if err != nil {
		t.Fatal(err)
	}
	childPID, err := strconv.Atoi(strings.Fields(string(children))[0])
	if err != nil {
		t.Fatal(err)
	}
	_ = parent.Process.Signal(syscall.SIGTERM)
	_ = parent.Wait()
	deadline := time.Now().Add(2 * time.Second)
	for (processAlive(controllerPID) || processAlive(childPID)) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if processAlive(controllerPID) || processAlive(childPID) {
		t.Fatalf("parent death left controller=%d or ssh=%d alive", controllerPID, childPID)
	}

	foreign := filepath.Join(runtime, "cockpit-nvim-foreign-remote.sock")
	blackhole, err := net.ListenUnix("unix", &net.UnixAddr{Name: foreign, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	result := runEnv(t, home, bin, []string{"XDG_RUNTIME_DIR=" + runtime, "VMCTL_EDITOR_NVIM=" + filepath.Join(bin, "nvim"), "VMCTL_LOG=" + log}, "editor", "foreign", "window-1")
	blackhole.Close()
	if result.err == nil || !strings.Contains(result.stderr, "refusing live editor endpoint") || time.Since(started) > time.Second {
		t.Fatalf("blackhole socket result=%+v elapsed=%s", result, time.Since(started))
	}
}

func TestEditorBuildsMissingNeovimOnTheVM(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	runtime, err := os.MkdirTemp("/tmp", "vml-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(runtime)
	if err := os.MkdirAll(filepath.Join(runtime, "quickshell/by-id/window-1"), 0o700); err != nil {
		t.Fatal(err)
	}
	qs, err := net.Listen("unix", filepath.Join(runtime, "quickshell/by-id/window-1/ipc.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer qs.Close()
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(home, "calls")
	missing := filepath.Join(home, "missing")
	if err := os.WriteFile(missing, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(bin, "ssh"), `#!/bin/sh
printf 'ssh|%s\n' "$*" >> "$VMCTL_LOG"
case " $* " in
  *" test -x "*) test ! -f "$VMCTL_REMOTE_MISSING" ;;
  *"nix-store --add-root"*) rm -f "$VMCTL_REMOTE_MISSING" ;;
  *) sleep 30 ;;
esac
`)
	writeExecutable(t, filepath.Join(bin, "nix-store"), "#!/bin/sh\nprintf 'nix-store|%s\\n' \"$*\" >> \"$VMCTL_LOG\"; echo /nix/store/hash-neovim.drv\n")
	writeExecutable(t, filepath.Join(bin, "nix"), "#!/bin/sh\nprintf 'nix|%s|%s\\n' \"$*\" \"$NIX_SSHOPTS\" >> \"$VMCTL_LOG\"\n")
	cmd := exec.Command(binary, "editor", "demo", "window-1")
	cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+bin, "XDG_RUNTIME_DIR="+runtime,
		"VMCTL_EDITOR_NVIM=/nix/store/hash-neovim/bin/nvim", "VMCTL_LOG="+log, "VMCTL_REMOTE_MISSING="+missing)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(missing); os.IsNotExist(err) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	calls, _ := os.ReadFile(log)
	text := string(calls)
	for _, want := range []string{
		"nix-store|--query --deriver /nix/store/hash-neovim\n",
		"nix|copy --derivation --to ssh-ng://david_karlsson_lovable_dev@",
		"BatchMode=yes",
		"nix-store --add-root \"$HOME/.local/state/cockpit-gcroots/editor-nvim\" --realise /nix/store/hash-neovim.drv",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q:\n%s", want, text)
		}
	}
}

func startEditorCLI(t *testing.T, env []string) (*exec.Cmd, string) {
	t.Helper()
	cmd := exec.Command(binary, "editor", "demo", "window-1")
	cmd.Env = env
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	line := make(chan string, 1)
	go func() { value, _ := bufio.NewReader(stdout).ReadString('\n'); line <- strings.TrimSpace(value) }()
	select {
	case value := <-line:
		return cmd, value
	case <-time.After(3 * time.Second):
		cmd.Process.Kill()
		t.Fatal("editor CLI did not report a reachable socket")
		return nil, ""
	}
}

func readLine(t *testing.T, reader *bufio.Reader) string {
	t.Helper()
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	return line
}

func processAlive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func writeExecutable(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o755); err != nil {
		t.Fatal(err)
	}
}
