package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func worktreeProxyHost(ports worktreePorts) (string, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Get("http://127.0.0.1:2019/config/apps/http/servers")
	if err != nil {
		return "", fmt.Errorf("shared wt-proxy is unavailable: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("wt-proxy configuration returned HTTP %d", response.StatusCode)
	}
	var servers map[string]struct {
		Routes []struct {
			Match  []struct{ Host []string }
			Handle []struct {
				Routes []struct {
					Handle []struct {
						Upstreams []struct{ Dial string }
					}
				}
			}
		}
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&servers); err != nil {
		return "", err
	}
	for _, server := range servers {
		for _, route := range server.Routes {
			web, api := false, false
			for _, handler := range route.Handle {
				for _, child := range handler.Routes {
					for _, proxy := range child.Handle {
						for _, upstream := range proxy.Upstreams {
							web = web || upstream.Dial == fmt.Sprintf("localhost:%d", ports.web)
							api = api || upstream.Dial == fmt.Sprintf("localhost:%d", ports.api)
						}
					}
				}
			}
			if web && api && len(route.Match) == 1 && len(route.Match[0].Host) == 1 && strings.HasSuffix(route.Match[0].Host[0], ".localhost") {
				return route.Match[0].Host[0], nil
			}
		}
	}
	return "", fmt.Errorf("wt-proxy has no route for web %d and API %d", ports.web, ports.api)
}

func ensureDevProxyTunnel(a app) error {
	if a.nativeVM() {
		return fmt.Errorf("run vmctl connect on the desktop, not the VM")
	}
	ssh, err := exec.LookPath("ssh")
	if err != nil {
		return err
	}
	args := []string{ssh, "-fN", "-o", "AddressFamily=any", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "StrictHostKeyChecking=yes", "-L", "127.0.0.1:2015:127.0.0.1:2015", a.user + "@" + a.host}
	for i, arg := range args {
		args[i] = strconv.Quote(strings.NewReplacer("%", "%%", "$", "$$").Replace(arg))
	}
	unit := "vm-dev-tunnel.service"
	content := "[Unit]\nDescription=VM shared development router tunnel\nAfter=network-online.target\n\n[Service]\nType=forking\nExecStart=" + strings.Join(args, " ") + "\nRestart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=default.target\n"
	dir := filepath.Join(a.home, ".config", "systemd", "user")
	path := filepath.Join(dir, unit)
	previous, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if err == nil && string(previous) != content {
		return fmt.Errorf("%s has different configuration; inspect it before switching the shared tunnel to %s", path, a.host)
	}
	if os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			return err
		}
	}
	for _, args := range [][]string{{"--user", "daemon-reload"}, {"--user", "enable", "--now", unit}} {
		cmd := exec.Command("systemctl", args...)
		cmd.Stdout, cmd.Stderr = a.out, a.err
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("shared development tunnel failed: %w", err)
		}
	}
	fmt.Fprintf(a.out, "Desktop development tunnel ready: 127.0.0.1:2015 → %s:2015\n", a.host)
	return nil
}
