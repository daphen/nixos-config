package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var (
	ticketPattern = regexp.MustCompile(`(?i)^EVERY-[0-9]+$`)
	binaryPath    = regexp.MustCompile(`(?i)\.(png|jpg|jpeg|gif|webp|ico|icns|pdf|mp4|woff2?|ttf)$`)
)

type app struct {
	out, err io.Writer
	home     string
	user     string
	vm       string
	host     string
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
	if len(args) == 0 {
		return fmt.Errorf("usage: vmctl <sync|worktree|cockpit> [arguments]")
	}
	a, err := newApp(out, errOut)
	if err != nil {
		return err
	}
	switch args[0] {
	case "cockpit":
		if len(args) > 2 || (len(args) == 2 && args[1] != "--restart") {
			return fmt.Errorf("usage: vmctl cockpit [--restart]")
		}
		return runCockpit(a, len(args) == 2)
	case "sync":
		return syncCommand(a, args[1:])
	case "worktree":
		if len(args) != 2 {
			return fmt.Errorf("usage: vmctl worktree EVERY-N")
		}
		ticket, err := parseTicket(args[1])
		if err != nil {
			return err
		}
		return runWorktree(a, ticket, args[1])
	default:
		return fmt.Errorf("usage: vmctl <sync|worktree|cockpit> [arguments]")
	}
}

func syncCommand(a app, args []string) error {
	align := len(args) > 0 && args[0] == "--align"
	if align {
		args = args[1:]
	}
	if len(args) != 1 {
		return fmt.Errorf("usage: vmctl sync [--align] EVERY-N")
	}
	ticket, err := parseTicket(args[0])
	if err != nil {
		return err
	}
	if align {
		return a.align(ticket)
	}
	return a.sync(ticket, args[0])
}

func parseTicket(raw string) (string, error) {
	if !ticketPattern.MatchString(raw) {
		return "", fmt.Errorf("invalid ticket %q: expected EVERY-N", raw)
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

func (a app) align(ticket string) error {
	local := filepath.Join(a.home, "work", "lovable.daphen-"+ticket)
	if info, err := os.Stat(local); err != nil || !info.IsDir() {
		return nil
	}
	a.installDeps(local)

	base, err := a.output("git", "-C", local, "merge-base", "HEAD", "origin/main")
	if err != nil {
		return err
	}
	diffArgs := []string{"-C", local, "diff", "--name-only"}
	if strings.TrimSpace(base) != "" {
		diffArgs = append(diffArgs, strings.TrimSpace(base))
	}
	changed, err := a.output("git", diffArgs...)
	if err != nil {
		return err
	}
	if lineCount(changed) <= 150 {
		return nil
	}
	_ = a.quiet(nil, "git", "-C", local, "fetch", "-q", "--no-tags", "origin", "main")

	cm := filepath.Join(envDefault("XDG_RUNTIME_DIR", "/tmp"), "heidr-vm-cm")
	head, err := a.output("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
		"-o", "ControlMaster=auto", "-o", "ControlPath="+cm, "-o", "ControlPersist=600", "-o", "ConnectTimeout=20",
		a.user+"@"+a.host, "git -C '/home/"+a.user+"/src/lovable-"+ticket+"' rev-parse HEAD")
	head = strings.Join(strings.Fields(head), "")
	if err != nil || !isCommit(head) {
		return nil
	}
	cur, err := a.output("git", "-C", local, "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	cur = strings.TrimSpace(cur)
	if cur == head {
		return nil
	}
	if a.quiet(nil, "git", "-C", local, "cat-file", "-e", head+"^{commit}") != nil {
		sshEnv := []string{"GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlPath=" + cm}
		if a.quiet(sshEnv, "git", "-C", local, "fetch", "-q", "ssh://"+a.user+"@"+a.host+"/home/"+a.user+"/src/lovable", head) != nil &&
			a.quiet(nil, "git", "-C", local, "fetch", "-q", "origin", head) != nil {
			return nil
		}
	}
	if a.quiet(nil, "git", "-C", local, "reset", "-q", head) != nil {
		return nil
	}
	fmt.Fprintf(a.out, "[vm-sync] %s: HEAD %s -> %s (files untouched)\n", ticket, prefix(cur, 11), prefix(head, 11))
	return nil
}

func (a app) installDeps(local string) {
	if !isFile(filepath.Join(local, "package.json")) || isDir(filepath.Join(local, "node_modules")) {
		return
	}
	logPath := filepath.Join(local, ".pnpm-install.log")
	if info, err := os.Stat(logPath); err == nil && time.Since(info.ModTime()) < 10*time.Minute {
		return
	}
	allow := exec.Command("direnv", "allow", ".")
	allow.Dir, allow.Stdout, allow.Stderr = local, a.out, io.Discard
	if allow.Run() != nil {
		return
	}
	log, err := os.Create(logPath)
	if err != nil {
		return
	}
	cmd := exec.Command("nohup", "direnv", "exec", local, "pnpm", "install", "--frozen-lockfile", "--prefer-offline")
	cmd.Dir, cmd.Stdout, cmd.Stderr = local, log, log
	if cmd.Start() != nil {
		_ = log.Close()
	}
}

type syncRun struct {
	a                          app
	mutagen, vmwt, local, repo string
	name, vmhead               string
}

func newSyncRun(a app, ticket, raw string) (syncRun, error) {
	mutagen, err := exec.LookPath("mutagen")
	if err != nil {
		fmt.Fprintln(a.err, "✗ mutagen not on PATH")
		return syncRun{}, silentError{}
	}
	s := syncRun{
		a: a, mutagen: mutagen,
		vmwt:  "/home/" + a.user + "/src/lovable-" + ticket,
		local: filepath.Join(a.home, "work", "lovable.daphen-"+ticket),
		repo:  filepath.Join(a.home, "work", "lovable"),
		name:  "vmwt-" + ticket,
	}
	sshArgs := []string{"-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", a.user + "@" + a.host, "git -C '" + s.vmwt + "' rev-parse HEAD"}
	head, err := a.output("ssh", sshArgs...)
	if err != nil {
		return syncRun{}, silentError{}
	}
	s.vmhead = strings.Join(strings.Fields(head), "")
	if s.vmhead == "" {
		fmt.Fprintf(a.err, "✗ no worktree at %s on %s — run vm-wt %s first\n", s.vmwt, a.vm, raw)
		return syncRun{}, silentError{}
	}
	return s, nil
}

func (a app) sync(ticket, raw string) error {
	s, err := newSyncRun(a, ticket, raw)
	if err != nil {
		return err
	}
	a.say("VM head: " + prefix(s.vmhead, 11))
	if err := s.prepareCheckout(); err != nil {
		return err
	}
	if err := s.seedChanges(); err != nil {
		return err
	}
	s.ensureMutagen()
	return a.report(s.local)
}

func (s syncRun) prepareCheckout() error {
	s.a.say("pause sync while the checkout moves …")
	_ = s.a.quiet(nil, s.mutagen, "sync", "pause", s.name)
	s.a.say("refresh origin/main so the diff base is honest …")
	_ = s.a.quiet(nil, "git", "-C", s.repo, "fetch", "-q", "--no-tags", "origin", "main")
	if s.a.quiet(nil, "git", "-C", s.repo, "cat-file", "-e", s.vmhead+"^{commit}") != nil {
		s.a.say("fetching that commit from the VM …")
		sshEnv := []string{"GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"}
		if s.a.quiet(sshEnv, "git", "-C", s.repo, "fetch", "--quiet", "ssh://"+s.a.user+"@"+s.a.host+s.vmwt, s.vmhead) != nil &&
			s.a.quiet(sshEnv, "git", "-C", s.repo, "fetch", "--quiet", "ssh://"+s.a.user+"@"+s.a.host+"/home/"+s.a.user+"/src/lovable", s.vmhead) != nil {
			_ = s.a.quiet(nil, "git", "-C", s.repo, "fetch", "--quiet", "origin", s.vmhead)
		}
	}
	if pathExists(filepath.Join(s.local, ".git")) {
		s.a.say("align " + s.local + " to the VM's base …")
		if err := s.a.quiet(nil, "git", "-C", s.local, "checkout", "--force", "--detach", s.vmhead); err != nil {
			return err
		}
		return s.a.quiet(nil, "git", "-C", s.local, "clean", "-qfd")
	}
	s.a.say("create local worktree " + s.local + " at the VM's base …")
	text, err := s.a.combined("git", "-C", s.repo, "worktree", "add", "--detach", s.local, s.vmhead)
	if text != "" {
		fmt.Fprintln(s.a.out, lastLine(text))
	}
	return err
}

func (s syncRun) seedChanges() error {
	s.a.say("seed the agent's work one-way (rsync, so nothing bidirectional can eat it) …")
	s.a.rsync(s.vmwt, s.local)
	bins := s.a.binaryChanges(s.local)
	if bins == "" {
		return nil
	}
	cmd := exec.Command("git", append([]string{"update-index", "--skip-worktree"}, strings.Split(bins, "\n")...)...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = s.local, s.a.out, s.a.err
	if err := cmd.Run(); err != nil {
		return err
	}
	s.a.say(fmt.Sprintf("  hid %d LFS binaries from git status", lineCount(bins)))
	return nil
}

func (s syncRun) ensureMutagen() {
	if s.a.quiet(nil, s.mutagen, "sync", "list", s.name) == nil {
		s.a.say("resume sync …")
		_ = s.a.quiet(nil, s.mutagen, "sync", "resume", s.name)
		return
	}
	s.a.say("create sync (two-way-resolved, VM wins) …")
	args := []string{"sync", "create", "--name=" + s.name, "--sync-mode=two-way-resolved", "--watch-polling-interval=600"}
	for _, ignore := range mutagenIgnores {
		args = append(args, "--ignore="+ignore)
	}
	args = append(args, s.a.user+"@"+s.a.host+":"+s.vmwt, s.local)
	if s.a.quiet(nil, s.mutagen, args...) == nil {
		s.a.say("  created")
	} else {
		s.a.say("  ✗ create failed")
	}
}

var mutagenIgnores = []string{
	".git", "node_modules", ".devenv", ".direnv", ".wrangler", "*.sqlite", "*.sqlite-shm", "*.sqlite-wal",
	".next", ".turbo", "target", "dist", "__pycache__", ".venv", "bazel-*", "*.log", "*.png", "*.jpg",
	"*.jpeg", "*.gif", "*.webp", "*.ico", "*.icns", "*.pdf", "*.mp4", "*.woff", "*.woff2", "*.ttf", "!.heidr-pastes/**",
}

func (a app) rsync(vmwt, local string) {
	args := []string{"-a"}
	for _, pattern := range []string{".git", "node_modules", ".devenv", ".direnv", ".wrangler", "*.sqlite*", ".next", ".turbo", "target", "dist", "__pycache__", ".venv", "*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.ico", "*.icns", "*.pdf", "*.mp4", "*.woff", "*.woff2", "*.ttf"} {
		args = append(args, "--exclude", pattern)
	}
	args = append(args, "-e", "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null", a.user+"@"+a.host+":"+vmwt+"/", local+"/")
	text, _ := a.combined("rsync", args...)
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if line != "" && !strings.HasPrefix(line, "Warning:") {
			fmt.Fprintln(a.out, line)
		}
	}
}

func (a app) binaryChanges(local string) string {
	cmd := exec.Command("git", "status", "--porcelain")
	cmd.Dir, cmd.Env, cmd.Stderr = local, os.Environ(), io.Discard
	text, err := cmd.Output()
	if err != nil {
		return ""
	}
	var found []string
	for _, line := range strings.Split(string(text), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "M" && binaryPath.MatchString(fields[1]) {
			found = append(found, fields[1])
		}
	}
	return strings.Join(found, "\n")
}

func (a app) report(local string) error {
	a.say("local diff vs the VM's base:")
	status, err := a.output("git", "-C", local, "status", "--porcelain")
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSuffix(status, "\n"), "\n")
	for i, line := range lines {
		if i == 20 || line == "" {
			break
		}
		fmt.Fprintln(a.out, "    "+line)
	}
	stat, err := a.output("git", "-C", local, "diff", "--shortstat")
	if err != nil {
		return err
	}
	if stat = strings.TrimSuffix(stat, "\n"); stat != "" {
		fmt.Fprintln(a.out, "    "+stat)
	}
	a.say("done — nvim gets gutter hunks and <C-g>j/k in " + local)
	return nil
}

func (a app) say(text string) { fmt.Fprintf(a.out, "\x1b[36m[vm-sync]\x1b[0m %s\n", text) }

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
func (a app) quiet(env []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Env, cmd.Stdout, cmd.Stderr = commandEnv(env), io.Discard, io.Discard
	return cmd.Run()
}

func commandEnv(extra []string) []string { return append(os.Environ(), extra...) }
func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func lineCount(text string) int {
	text = strings.TrimSpace(text)
	if text == "" {
		return 0
	}
	return strings.Count(text, "\n") + 1
}
func isCommit(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}
func isFile(path string) bool { info, err := os.Stat(path); return err == nil && !info.IsDir() }
func isDir(path string) bool  { info, err := os.Stat(path); return err == nil && info.IsDir() }
func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
func prefix(value string, n int) string {
	if len(value) < n {
		return value
	}
	return value[:n]
}
func lastLine(value string) string {
	lines := strings.Split(strings.TrimSuffix(value, "\n"), "\n")
	return lines[len(lines)-1]
}

type silentError struct{}

func (silentError) Error() string { return "" }
