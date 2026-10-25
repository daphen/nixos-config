package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	goruntime "runtime"
	"strings"
	"syscall"
	"time"
)

const prSetPdeathsig = 1

var editorNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

func runEditor(a app, instance, qsInstance string) error {
	parentPID := os.Getppid()
	if !editorNamePattern.MatchString(instance) || !editorNamePattern.MatchString(qsInstance) {
		return fmt.Errorf("editor instance and Quickshell instance must contain only letters, numbers, '.', '_' or '-'")
	}
	runtime := os.Getenv("XDG_RUNTIME_DIR")
	if !filepath.IsAbs(runtime) {
		return fmt.Errorf("XDG_RUNTIME_DIR must be an absolute path")
	}
	nvim := os.Getenv("VMCTL_EDITOR_NVIM")
	if !filepath.IsAbs(nvim) {
		return fmt.Errorf("VMCTL_EDITOR_NVIM must name the packaged Neovim executable")
	}
	localSocket := filepath.Join(runtime, "cockpit-nvim-"+instance+"-remote.sock")
	localQS := filepath.Join(runtime, "quickshell", "by-id", qsInstance, "ipc.sock")
	if info, err := os.Stat(localQS); err != nil || info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("Quickshell IPC socket is unavailable: %s", localQS)
	}
	goruntime.LockOSThread()
	defer goruntime.UnlockOSThread()
	if _, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, prSetPdeathsig, uintptr(syscall.SIGTERM), 0, 0, 0, 0); errno != 0 {
		return fmt.Errorf("set parent-death signal: %w", errno)
	}
	if os.Getppid() != parentPID {
		return fmt.Errorf("editor parent exited during startup")
	}
	for {
		if err := prepareLocalForward(localSocket, nvim, a.user+"@"+a.host); err != nil {
			return err
		}
		if err := ensureRemoteNvim(a, nvim); err != nil {
			fmt.Fprintf(a.err, "vmctl editor: %v; retrying\n", err)
			time.Sleep(5 * time.Second)
			continue
		}
		remoteRuntime, err := prepareRemoteEditor(a, instance, qsInstance, nvim)
		if err != nil {
			fmt.Fprintf(a.err, "vmctl editor: %v; retrying\n", err)
			time.Sleep(time.Second)
			continue
		}
		base := "cockpit-nvim-" + instance + "-remote.sock"
		remoteSocket := filepath.Join(remoteRuntime, "cockpit-editors", base)
		remoteQS := filepath.Join(remoteRuntime, "quickshell", "by-id", qsInstance, "ipc.sock")
		ssh := exec.Command("ssh", append(sshOptions(),
			"-o", "ExitOnForwardFailure=yes", "-N",
			"-L", localSocket+":"+remoteSocket, "-R", remoteQS+":"+localQS,
			a.user+"@"+a.host)...)
		ssh.Stdout, ssh.Stderr = a.err, a.err
		ssh.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
		if err := ssh.Start(); err != nil {
			fmt.Fprintf(a.err, "vmctl editor: SSH start failed: %v; retrying\n", err)
			time.Sleep(time.Second)
			continue
		}
		done := make(chan error, 1)
		go func() { done <- ssh.Wait() }()
		connected := false
		for !connected {
			select {
			case err := <-done:
				fmt.Fprintf(a.err, "vmctl editor: SSH disconnected: %v; retrying\n", err)
				connected = true
			case <-time.After(50 * time.Millisecond):
				if nvimReachable(nvim, localSocket) {
					fmt.Fprintln(a.out, localSocket)
					err := <-done
					fmt.Fprintf(a.err, "vmctl editor: SSH disconnected: %v; retrying\n", err)
					connected = true
				}
			}
		}
		time.Sleep(time.Second)
	}
}

func prepareLocalForward(socket, nvim, owner string) error {
	marker := socket + ".owner"
	owned, markerErr := os.ReadFile(marker)
	if markerErr != nil && !os.IsNotExist(markerErr) {
		return markerErr
	}
	if info, err := os.Lstat(socket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return fmt.Errorf("refusing non-socket editor endpoint %s", socket)
		}
		conn, dialErr := net.DialTimeout("unix", socket, 150*time.Millisecond)
		if dialErr == nil {
			_ = conn.Close()
			return fmt.Errorf("refusing live editor endpoint %s", socket)
		}
		if !errors.Is(dialErr, syscall.ECONNREFUSED) {
			return fmt.Errorf("refusing unverifiable editor endpoint %s: %w", socket, dialErr)
		}
		if string(owned) != owner+"\n" {
			return fmt.Errorf("refusing unowned editor endpoint %s", socket)
		}
		if err := os.Remove(socket); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if markerErr == nil {
		if string(owned) != owner+"\n" {
			return fmt.Errorf("refusing mismatched editor owner for %s", socket)
		}
		return nil
	}
	return os.WriteFile(marker, []byte(owner+"\n"), 0o600)
}

func nvimReachable(nvim, socket string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, nvim, "--server", socket, "--remote-expr", "exists(':CockpitEdit')").Output()
	return err == nil && strings.TrimSpace(string(output)) == "2"
}

func prepareRemoteEditor(a app, instance, qsInstance, nvim string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ssh", append(sshOptions(), a.user+"@"+a.host, "sh", "-s", "--", instance, qsInstance, nvim)...)
	cmd.Stdin = strings.NewReader(`set -eu
instance=$1 qsid=$2 nvim=$3
runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
dir=$runtime/cockpit-editors
socket=$dir/cockpit-nvim-$instance-remote.sock
unit=cockpit-editor-$instance.service
qsdir=$runtime/quickshell/by-id/$qsid
qssocket=$qsdir/ipc.sock
editor_owner=$socket.owner
forward_owner=$qsdir/.cockpit-editor-owner
umask 077
mkdir -p "$dir" "$qsdir"
chmod 700 "$dir" "$runtime/quickshell" "$runtime/quickshell/by-id" "$qsdir"
if [ -e "$editor_owner" ]; then
  [ -f "$editor_owner" ] && [ "$(cat "$editor_owner")" = "$unit" ] || exit 1
fi
cockpit_ready() {
  [ "$(timeout .5 "$nvim" --server "$socket" --remote-expr "exists(':CockpitEdit')" 2>/dev/null)" = 2 ]
}
if systemctl --user is-active --quiet "$unit"; then
  [ "$(systemctl --user show "$unit" --property=Description --value)" = "Cockpit remote editor $instance" ] || exit 1
  cockpit_ready
else
  if [ -e "$socket" ]; then
    [ -S "$socket" ] && [ -f "$editor_owner" ] && [ "$(cat "$editor_owner")" = "$unit" ] || exit 1
    cockpit_ready && exit 1
    rm -f "$socket"
  fi
  printf '%s\n' "$unit" > "$editor_owner"
  systemctl --user reset-failed "$unit" 2>/dev/null || true
  systemd-run --user --unit "$unit" --description="Cockpit remote editor $instance" --property=Restart=no \
    --setenv=COCKPIT_INSTANCE="$instance" --setenv=COCKPIT_COCKPIT=1 --setenv=COCKPIT_SCOPE=lovable \
    -- "$nvim" --headless --listen "$socket" >/dev/null
  i=0; until cockpit_ready; do
    i=$((i+1)); [ "$i" -lt 20 ] || exit 1; sleep .05
  done
fi
if [ -e "$forward_owner" ]; then
  [ -f "$forward_owner" ] && [ "$(cat "$forward_owner")" = "$instance" ] || exit 1
fi
if [ -e "$qssocket" ]; then
  [ -S "$qssocket" ] && [ -f "$forward_owner" ] && [ "$(cat "$forward_owner")" = "$instance" ] || exit 1
  ! ss -H -xl | grep -F -- "$qssocket" >/dev/null || exit 1
  rm -f "$qssocket"
fi
printf '%s\n' "$instance" > "$forward_owner"
chmod 600 "$editor_owner" "$forward_owner"
printf '%s\n' "$runtime"
`)
	cmd.Stderr = a.err
	value, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("remote editor setup failed: %w", err)
	}
	runtime := strings.TrimSpace(string(value))
	if !filepath.IsAbs(runtime) || strings.ContainsAny(runtime, "\r\n") {
		return "", fmt.Errorf("remote returned invalid runtime directory %q", runtime)
	}
	return runtime, nil
}

// The editor build changes with every desktop Neovim edit; the VM cannot accept
// unsigned local outputs, so it builds the same derivation itself.
func ensureRemoteNvim(a app, nvim string) error {
	target := a.user + "@" + a.host
	if exec.Command("ssh", append(sshOptions(), target, "test", "-x", nvim)...).Run() == nil {
		return nil
	}
	parts := strings.SplitN(nvim, "/", 5)
	if len(parts) < 5 || parts[1] != "nix" || parts[2] != "store" {
		return fmt.Errorf("editor Neovim %s is not a Nix store path", nvim)
	}
	deriver, err := exec.Command("nix-store", "--query", "--deriver", "/nix/store/"+parts[3]).Output()
	drv := strings.TrimSpace(string(deriver))
	if err != nil || !strings.HasSuffix(drv, ".drv") {
		return fmt.Errorf("cannot find the derivation for %s", nvim)
	}
	fmt.Fprintf(a.err, "vmctl editor: building %s on the VM\n", nvim)
	copy := exec.Command("nix", "copy", "--derivation", "--to", "ssh-ng://"+target, drv)
	copy.Env = append(os.Environ(), "NIX_SSHOPTS="+strings.Join(sshOptions(), " "))
	copy.Stderr = a.err
	if err := copy.Run(); err != nil {
		return fmt.Errorf("copy editor derivation: %w", err)
	}
	build := exec.Command("ssh", append(sshOptions(), target, `mkdir -p "$HOME/.local/state/cockpit-gcroots" && nice -n 10 nix-store --add-root "$HOME/.local/state/cockpit-gcroots/editor-nvim" --realise `+drv+` >/dev/null`)...)
	build.Stderr = a.err
	if err := build.Run(); err != nil {
		return fmt.Errorf("build editor Neovim on the VM: %w", err)
	}
	return nil
}

func sshOptions() []string {
	return strings.Fields("-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null")
}
