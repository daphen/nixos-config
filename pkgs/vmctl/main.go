package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	ticketPattern           = regexp.MustCompile(`(?i)^[A-Z][A-Z0-9]*-[0-9]+$`)
	explicitCheckoutPattern = regexp.MustCompile(`^lovable\.[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

type app struct {
	out, err io.Writer
	home     string
	user     string
	vm       string
	host     string
	native   bool
}

func (a app) nativeVM() bool { return a.native }

func (a app) vmRepo() string {
	if a.nativeVM() {
		return filepath.Join(a.home, "src", "lovable")
	}
	return "/home/" + a.user + "/src/lovable"
}

func main() {
	if err := command(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		_, silent := err.(silentError)
		_, commandFailed := err.(*exec.ExitError)
		if !silent && !commandFailed {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}

func command(args []string, out, errOut io.Writer) error {
	native := len(args) > 0 && args[0] == "--native"
	if native {
		args = args[1:]
	}
	if len(args) == 0 {
		return fmt.Errorf("usage: vmctl <worktree|cockpit|agentd|connect|editor> [arguments]")
	}
	a, err := newApp(out, errOut)
	if err != nil {
		return err
	}
	a.native = native
	switch args[0] {
	case "connect":
		if len(args) != 1 {
			return fmt.Errorf("usage: vmctl connect")
		}
		return ensureDevProxyTunnel(a)
	case "editor":
		if len(args) != 3 {
			return fmt.Errorf("usage: vmctl editor INSTANCE QS_INSTANCE_ID")
		}
		return runEditor(a, args[1], args[2])
	case "cockpit":
		if len(args) > 2 || (len(args) == 2 && args[1] != "--restart") {
			return fmt.Errorf("usage: vmctl cockpit [--restart]")
		}
		return runCockpit(a, len(args) == 2)
	case "agentd":
		if len(args) != 1 {
			return fmt.Errorf("usage: vmctl agentd")
		}
		return runAgentd(a)
	case "worktree":
		if len(args) > 1 && args[1] == "--review" {
			if len(args) != 4 {
				return fmt.Errorf("usage: vmctl worktree --review PR-NUMBER HEAD-SHA")
			}
			return runReviewWorktree(a, args[2], args[3])
		}
		teardown := len(args) == 3 && args[1] == "--teardown"
		off := len(args) == 3 && args[1] == "--off"
		reap := len(args) == 3 && args[1] == "--reap"
		scriptTag := len(args) == 3 && args[1] == "--script-tag"
		startApp := scriptTag || (len(args) == 3 && args[1] == "--app")
		if len(args) != 2 && !teardown && !off && !reap && !startApp {
			return fmt.Errorf("usage: vmctl worktree [--off | --reap | --teardown | --app | --script-tag] TEAM-N | --review PR-NUMBER HEAD-SHA")
		}
		raw := args[len(args)-1]
		ticket, err := parseTicket(raw)
		if err != nil {
			return err
		}
		if teardown {
			return teardownWorktreeTunnel(a, ticket)
		}
		if off || reap {
			return finishWorktree(a, ticket, reap)
		}
		return runWorktree(a, ticket, raw, startApp, scriptTag)
	default:
		return fmt.Errorf("usage: vmctl <worktree|cockpit|agentd|connect|editor> [arguments]")
	}
}

func parseTicket(raw string) (string, error) {
	if !ticketPattern.MatchString(raw) {
		return "", fmt.Errorf("invalid ticket %q: expected TEAM-N such as EVERY-123 or PLS-683", raw)
	}
	return strings.ToLower(raw), nil
}

func newApp(out, errOut io.Writer) (app, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return app{}, err
	}
	a := app{
		out: out, err: errOut, home: home,
		user: envFallback("COCKPIT_VM_USER", "HEIDR_VM_USER", "david_karlsson_lovable_dev"),
		vm:   envFallback("COCKPIT_VM", "HEIDR_VM", "dev-heidr-2a39"),
	}
	a.host = envFallback("COCKPIT_VM_HOST", "HEIDR_VM_HOST", a.vm+".workstation.lovable.net")
	return a, nil
}

func envFallback(primary, legacy, fallback string) string {
	if value := os.Getenv(primary); value != "" {
		return value
	}
	if value := os.Getenv(legacy); value != "" {
		return value
	}
	return fallback
}

func (a app) output(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Stderr = io.Discard
	value, err := cmd.Output()
	return string(value), err
}
func (a app) combined(name string, args ...string) (string, error) {
	value, err := exec.Command(name, args...).CombinedOutput()
	return string(value), err
}

func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func isDir(path string) bool { info, err := os.Stat(path); return err == nil && info.IsDir() }
func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

type silentError struct{}

func (silentError) Error() string { return "" }
