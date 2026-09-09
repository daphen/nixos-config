package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	ticketPattern           = regexp.MustCompile(`(?i)^EVERY-[0-9]+$`)
	explicitCheckoutPattern = regexp.MustCompile(`^lovable\.[A-Za-z0-9][A-Za-z0-9._-]*$`)
	lfsPointerPattern       = regexp.MustCompile(`^version https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize ([0-9]+)\n?$`)
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
		teardown := len(args) == 3 && args[1] == "--teardown"
		scriptTag := len(args) == 3 && args[1] == "--script-tag"
		if len(args) != 2 && !teardown && !scriptTag {
			return fmt.Errorf("usage: vmctl worktree [--teardown | --script-tag] EVERY-N")
		}
		raw := args[len(args)-1]
		ticket, err := parseTicket(raw)
		if err != nil {
			return err
		}
		if teardown {
			return teardownWorktreeTunnel(a, ticket)
		}
		return runWorktree(a, ticket, raw, scriptTag)
	default:
		return fmt.Errorf("usage: vmctl <sync|worktree|cockpit> [arguments]")
	}
}

func syncCommand(a app, args []string) error {
	align, prepare, repair := false, false, false
	remoteCwd, repairPath, repairOID, repairSize := "", "", "", int64(0)
	for len(args) > 0 {
		switch args[0] {
		case "--align":
			align = true
			args = args[1:]
		case "--prepare":
			prepare = true
			args = args[1:]
		case "--repair":
			if len(args) < 4 {
				return fmt.Errorf("usage: vmctl sync --repair PATH LFS_SHA256 SIZE EVERY-N")
			}
			repair = true
			repairPath, repairOID = args[1], args[2]
			var err error
			repairSize, err = strconv.ParseInt(args[3], 10, 64)
			if err != nil {
				return fmt.Errorf("invalid repair size %q", args[3])
			}
			args = args[4:]
		case "--remote-cwd":
			if len(args) < 2 {
				return fmt.Errorf("usage: vmctl sync [--prepare | --align] [--remote-cwd VM_CHECKOUT] EVERY-N")
			}
			remoteCwd = args[1]
			args = args[2:]
		default:
			goto parsed
		}
	}
parsed:
	if len(args) != 1 || boolCount(align, prepare, repair) > 1 {
		return fmt.Errorf("usage: vmctl sync [--prepare | --align | --repair PATH LFS_SHA256 SIZE] [--remote-cwd VM_CHECKOUT] EVERY-N")
	}
	ticket, err := parseTicket(args[0])
	if err != nil {
		return err
	}
	if align {
		return a.align(ticket, args[0], remoteCwd)
	}
	if repair {
		s, err := newSyncRun(a, ticket, args[0], remoteCwd)
		if err != nil {
			return err
		}
		return s.repairIncompleteCheckout(repairPath, repairOID, repairSize)
	}
	return a.sync(ticket, args[0], remoteCwd, prepare)
}

func boolCount(values ...bool) int {
	count := 0
	for _, value := range values {
		if value {
			count++
		}
	}
	return count
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

func (a app) align(ticket, raw, remoteCwd string) error {
	s, err := newSyncRun(a, ticket, raw, remoteCwd)
	if err != nil {
		return err
	}
	if err := s.requireManaged(); err != nil {
		return err
	}
	if !pathExists(filepath.Join(s.local, ".git")) {
		return fmt.Errorf("mirror missing: %s", s.local)
	}
	if err := s.fetchVMBranch(); err != nil {
		return err
	}
	return s.alignHead()
}

func (a app) prepareMirrorDependencies(local string) error {
	if !isFile(filepath.Join(local, "package.json")) {
		return fmt.Errorf("mirror dependency setup refused: %s/package.json is missing", local)
	}
	allow := exec.Command("direnv", "allow", local)
	allow.Stdout, allow.Stderr = a.out, a.err
	if err := allow.Run(); err != nil {
		return fmt.Errorf("direnv allow failed in %s: %w", local, err)
	}
	steps := []struct {
		name string
		args []string
	}{
		{"pnpm install", []string{"install", "--frozen-lockfile", "--prefer-offline"}},
		{"web Paraglide generation", []string{"--dir", "web", "run", "paraglide:build"}},
	}
	for _, step := range steps {
		fmt.Fprintf(a.out, "[vm-sync] %s in %s …\n", step.name, local)
		args := append([]string{"exec", local, "pnpm"}, step.args...)
		cmd := exec.Command("direnv", args...)
		cmd.Dir, cmd.Stdout, cmd.Stderr = local, a.out, a.err
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("%s failed in %s: %w", step.name, local, err)
		}
	}
	return nil
}

type syncRun struct {
	a                                      app
	mutagen, wt, gitLFS, vmwt, local, repo string
	name, vmhead, vmbranch                 string
}

func explicitSyncPaths(a app, ticket, remoteCwd string) (string, string, string, error) {
	root := "/home/" + a.user + "/src"
	clean := filepath.Clean(remoteCwd)
	base := filepath.Base(clean)
	marker := "-" + ticket
	at := strings.Index(strings.ToLower(base), marker)
	if clean != remoteCwd || filepath.Dir(clean) != root || !explicitCheckoutPattern.MatchString(base) ||
		at < 0 || (len(base) > at+len(marker) && base[at+len(marker)] != '-') {
		return "", "", "", fmt.Errorf("invalid VM checkout %q: expected %s/lovable.<name>-%s[-suffix]", remoteCwd, root, ticket)
	}
	return clean, filepath.Join(a.home, "work", base), "vmwt-" + strings.TrimPrefix(base, "lovable."), nil
}

func newSyncRun(a app, ticket, raw, remoteCwd string) (syncRun, error) {
	s := syncRun{
		a:     a,
		vmwt:  "/home/" + a.user + "/src/lovable-" + ticket,
		local: filepath.Join(a.home, "work", "lovable.daphen-"+ticket),
		repo:  filepath.Join(a.home, "work", "lovable"),
		name:  "vmwt-" + ticket,
	}
	if remoteCwd != "" {
		var err error
		s.vmwt, s.local, s.name, err = explicitSyncPaths(a, ticket, remoteCwd)
		if err != nil {
			return syncRun{}, err
		}
	}
	var err error
	if s.mutagen, err = executable(a.home, "mutagen"); err != nil {
		return syncRun{}, err
	}
	if s.wt, err = executable(a.home, "wt"); err != nil {
		return syncRun{}, err
	}
	if s.gitLFS, err = executable(a.home, "git-lfs"); err != nil {
		return syncRun{}, err
	}
	if err := a.quiet(nil, s.gitLFS, "version"); err != nil {
		return syncRun{}, fmt.Errorf("git-lfs preflight failed: %w", err)
	}
	sshArgs := []string{"-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", a.user + "@" + a.host,
		"test -d '" + s.vmwt + "' && git -C '" + s.vmwt + "' rev-parse HEAD && git -C '" + s.vmwt + "' branch --show-current"}
	details, err := a.output("ssh", sshArgs...)
	if err != nil {
		fmt.Fprintf(a.err, "✗ VM checkout does not exist: %s\n", s.vmwt)
		return syncRun{}, silentError{}
	}
	lines := strings.Fields(details)
	if len(lines) > 0 {
		s.vmhead = lines[0]
	}
	if len(lines) > 1 {
		s.vmbranch = lines[1]
	}
	if !isCommit(s.vmhead) {
		fmt.Fprintf(a.err, "✗ no worktree at %s on %s — run vm-wt %s first\n", s.vmwt, a.vm, raw)
		return syncRun{}, silentError{}
	}
	return s, nil
}

func (a app) sync(ticket, raw, remoteCwd string, prepareOnly bool) error {
	s, err := newSyncRun(a, ticket, raw, remoteCwd)
	if err != nil {
		return err
	}
	if _, err := s.managedSession(); err != nil {
		return err
	}
	a.say("VM head: " + prefix(s.vmhead, 11))
	created, err := s.prepareCheckout()
	if err != nil {
		return err
	}
	if created {
		if err := s.seedNewMirror(); err != nil {
			return err
		}
		if err := s.refreshSeedStatCache(); err != nil {
			return err
		}
	}
	if err := s.ensureMutagen(); err != nil {
		return err
	}
	current, err := a.output("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", a.user+"@"+a.host, "git -C '"+s.vmwt+"' rev-parse HEAD")
	if err != nil || strings.TrimSpace(current) != s.vmhead {
		return fmt.Errorf("VM HEAD moved during sync; captured %s, now %s; retry preparation", prefix(s.vmhead, 11), prefix(strings.TrimSpace(current), 11))
	}
	if !created {
		if err := s.alignHead(); err != nil {
			return err
		}
	}
	localHead, err := a.output("git", "-C", s.local, "rev-parse", "HEAD")
	if err != nil || strings.TrimSpace(localHead) != s.vmhead {
		return fmt.Errorf("mirror head verification failed for %s: expected %s, got %s", s.local, prefix(s.vmhead, 11), prefix(strings.TrimSpace(localHead), 11))
	}
	if prepareOnly {
		a.say("prepared files, Git metadata, and sync without dependency or environment execution")
		return a.report(s.local)
	}
	if err := a.prepareMirrorDependencies(s.local); err != nil {
		return err
	}
	return a.report(s.local)
}

func (s syncRun) prepareCheckout() (bool, error) {
	if err := s.fetchVMBranch(); err != nil {
		return false, err
	}
	if pathExists(s.local) {
		if !pathExists(filepath.Join(s.local, ".git")) {
			return false, fmt.Errorf("refusing existing destination %s: not a git checkout", s.local)
		}
		managed, err := s.managedSession()
		if err != nil {
			return false, err
		}
		if !managed {
			if err := s.requireCleanIncompleteCheckout(); err != nil {
				return false, err
			}
		}
		return false, nil
	}
	if s.vmbranch == "" {
		return false, fmt.Errorf("VM checkout %s is detached; refusing to invent a local mirror branch", s.vmwt)
	}
	if err := s.a.quiet(nil, "git", "check-ref-format", "--branch", s.vmbranch); err != nil {
		return false, fmt.Errorf("invalid VM branch %q", s.vmbranch)
	}
	if s.a.quiet(nil, "git", "-C", s.repo, "show-ref", "--verify", "--quiet", "refs/heads/"+s.vmbranch) == nil {
		return false, fmt.Errorf("refusing existing local branch %s without its expected worktree", s.vmbranch)
	}
	args := []string{"-C", s.repo, "switch", "--create", s.vmbranch, "--base", s.vmhead, "--no-verify", "--no-cd", "-y"}
	s.a.say("create local mirror with Worktrunk at " + s.local + " …")
	cmd := exec.Command(s.wt, args...)
	cmd.Env = append(os.Environ(), "COLUMNS=120", "WORKTRUNK_WORKTREE_PATH="+s.local)
	if text, err := cmd.CombinedOutput(); err != nil {
		return false, fmt.Errorf("Worktrunk mirror creation failed: %s", strings.TrimSpace(string(text)))
	}
	if root, err := s.a.output("git", "-C", s.local, "rev-parse", "--show-toplevel"); err != nil || filepath.Clean(strings.TrimSpace(root)) != s.local {
		return false, fmt.Errorf("Worktrunk did not create the expected mirror %s", s.local)
	}
	return true, nil
}

func (s syncRun) seedNewMirror() error {
	s.a.say("seed new mirror one-way from the VM before enabling two-way sync …")
	args := []string{"-a", "--delete", "--exclude=.git", "--exclude=node_modules", "--exclude=.devenv", "--exclude=.direnv", "--exclude=.wrangler", "--exclude=.envrc.local", "--exclude=.env.local", "--exclude=.env", "--exclude=*.sqlite*", "--exclude=.next", "--exclude=.turbo", "--exclude=target", "--exclude=dist", "--exclude=__pycache__", "--exclude=.venv", "--exclude=/bazel-*"}
	args = append(args, "-e", "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null", s.a.user+"@"+s.a.host+":"+s.vmwt+"/", s.local+"/")
	cmd := exec.Command("rsync", args...)
	cmd.Stdout, cmd.Stderr = s.a.out, s.a.err
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("initial one-way mirror seed failed: %w", err)
	}
	return nil
}

func (s syncRun) refreshSeedStatCache() error {
	if s.a.quiet(nil, "git", "-C", s.local, "diff", "--cached", "--quiet") != nil ||
		s.a.quiet(nil, "git", "-C", s.local, "diff", "--no-ext-diff", "--no-textconv", "--quiet") != nil {
		return nil
	}
	before, err := s.a.output("git", "-C", s.local, "write-tree")
	if err != nil {
		return err
	}
	if err := s.a.quiet(nil, "git", "-C", s.local, "add", "--update"); err != nil {
		return fmt.Errorf("LFS stat refresh failed: %w", err)
	}
	after, err := s.a.output("git", "-C", s.local, "write-tree")
	if err != nil {
		return err
	}
	if strings.TrimSpace(before) != strings.TrimSpace(after) {
		_ = s.a.quiet(nil, "git", "-C", s.local, "read-tree", strings.TrimSpace(before))
		return fmt.Errorf("LFS stat refresh changed the index tree; original tree restored")
	}
	return nil
}

func (s syncRun) fetchVMBranch() error {
	if s.vmbranch == "" {
		return nil
	}
	sshEnv := []string{"GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"}
	url := "ssh://" + s.a.user + "@" + s.a.host + "/home/" + s.a.user + "/src/lovable"
	if s.a.quiet(sshEnv, "git", "-C", s.repo, "fetch", "--quiet", "--no-tags", url, s.vmbranch) != nil {
		return fmt.Errorf("could not fetch VM branch %s", s.vmbranch)
	}
	got, err := s.a.output("git", "-C", s.repo, "rev-parse", "FETCH_HEAD")
	if err != nil || strings.TrimSpace(got) != s.vmhead {
		return fmt.Errorf("fetched branch %s is not VM HEAD %s", s.vmbranch, prefix(s.vmhead, 11))
	}
	return nil
}

func (s syncRun) alignHead() error {
	cur, err := s.a.output("git", "-C", s.local, "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	cur = strings.TrimSpace(cur)
	if cur == s.vmhead {
		return nil
	}
	if s.a.quiet(nil, "git", "-C", s.local, "merge-base", "--is-ancestor", cur, s.vmhead) != nil {
		return fmt.Errorf("mirror HEAD %s diverges from VM HEAD %s; files and metadata left untouched", prefix(cur, 11), prefix(s.vmhead, 11))
	}
	if s.a.quiet(nil, "git", "-C", s.local, "diff", "--cached", "--quiet") != nil {
		return fmt.Errorf("mirror has staged changes; refusing HEAD/index alignment so staging is preserved")
	}
	if err := s.a.quiet(nil, "git", "-C", s.local, "reset", "--mixed", s.vmhead); err != nil {
		return err
	}
	fmt.Fprintf(s.a.out, "[vm-sync] HEAD/index %s -> %s (working files preserved)\n", prefix(cur, 11), prefix(s.vmhead, 11))
	return nil
}

type mutagenEndpoint struct {
	Protocol, User, Host, Path string
	Connected, Scanned         bool
}

type mutagenListing struct {
	Name        string `json:"name"`
	Alpha, Beta mutagenEndpoint
	Ignore      struct {
		Paths []string `json:"paths"`
	} `json:"ignore"`
	Paused bool   `json:"paused"`
	Status string `json:"status"`
}

func (s syncRun) repairIncompleteCheckout(path, expectedOID string, expectedSize int64) error {
	if filepath.Clean(path) != path || filepath.IsAbs(path) || strings.HasPrefix(path, "../") || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(expectedOID) || expectedSize < 0 || !ignoredByMutagen(path) {
		return fmt.Errorf("refusing repair: invalid or non-ignored LFS specification")
	}
	remoteStatus, err := s.a.output("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=25", s.a.user+"@"+s.a.host, "git -C '"+s.vmwt+"' status --porcelain --untracked-files=all")
	if err != nil || strings.TrimSpace(remoteStatus) != "" {
		return fmt.Errorf("refusing repair: VM checkout is not clean")
	}
	if managed, err := s.managedSession(); err != nil {
		return err
	} else if managed {
		return fmt.Errorf("refusing repair of managed mirror %s", s.local)
	}
	common, err := s.a.output("git", "-C", s.local, "rev-parse", "--path-format=absolute", "--git-common-dir")
	actualCommon, actualErr := filepath.EvalSymlinks(filepath.Clean(strings.TrimSpace(common)))
	expectedCommon, expectedErr := filepath.EvalSymlinks(filepath.Join(s.repo, ".git"))
	if err != nil || actualErr != nil || expectedErr != nil || actualCommon != expectedCommon {
		return fmt.Errorf("refusing repair: checkout is not owned by %s (got %s)", s.repo, strings.TrimSpace(common))
	}
	common = actualCommon
	if top, err := s.a.output("git", "-C", s.local, "rev-parse", "--show-toplevel"); err != nil || filepath.Clean(strings.TrimSpace(top)) != s.local {
		return fmt.Errorf("refusing repair: checkout identity is not exact")
	}
	branch, _ := s.a.output("git", "-C", s.local, "branch", "--show-current")
	head, err := s.a.output("git", "-C", s.local, "rev-parse", "HEAD")
	if strings.TrimSpace(branch) != "" || err != nil || strings.TrimSpace(head) != s.vmhead {
		return fmt.Errorf("refusing repair: expected detached HEAD %s", prefix(s.vmhead, 11))
	}
	if s.vmbranch == "" || s.a.quiet(nil, "git", "-C", s.repo, "show-ref", "--verify", "--quiet", "refs/heads/"+s.vmbranch) == nil {
		return fmt.Errorf("refusing repair: expected absent branch %s", s.vmbranch)
	}
	status, err := s.a.output("git", "-C", s.local, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	entries := strings.Split(strings.TrimSuffix(status, "\x00"), "\x00")
	if err != nil || len(entries) != 1 || entries[0] != " D "+path {
		return fmt.Errorf("refusing repair: unrelated or staged changes exist")
	}
	pointer, err := s.a.output("git", "-C", s.local, "show", ":"+path)
	match := lfsPointerPattern.FindStringSubmatch(pointer)
	if err != nil || match == nil || match[1] != expectedOID || match[2] != strconv.FormatInt(expectedSize, 10) {
		return fmt.Errorf("refusing repair: %s does not match the authorized LFS pointer", path)
	}
	object := filepath.Join(strings.TrimSpace(common), "lfs", "objects", expectedOID[:2], expectedOID[2:4], expectedOID)
	file, err := os.Open(object)
	if err != nil {
		return fmt.Errorf("refusing repair: verified LFS object missing for %s", path)
	}
	hash := sha256.New()
	written, copyErr := io.Copy(hash, file)
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written != expectedSize || fmt.Sprintf("%x", hash.Sum(nil)) != expectedOID {
		return fmt.Errorf("refusing repair: LFS object is invalid for %s", path)
	}
	args := []string{"checkout", "--", path}
	if err := s.a.quietIn(s.local, nil, s.gitLFS, args...); err != nil {
		return fmt.Errorf("LFS checkout failed for %s", s.local)
	}
	clean, err := s.a.output("git", "-C", s.local, "status", "--porcelain")
	if err != nil || strings.TrimSpace(clean) != "" {
		return fmt.Errorf("LFS checkout did not clean %s", s.local)
	}
	if err := s.a.quiet(nil, "git", "-C", s.local, "switch", "--create", s.vmbranch); err != nil {
		return fmt.Errorf("branch attachment failed for %s", s.vmbranch)
	}
	s.a.say("repaired detached mirror on " + s.vmbranch + " from verified local LFS objects")
	return nil
}

func ignoredByMutagen(path string) bool {
	for _, pattern := range mutagenIgnores {
		if !strings.HasPrefix(pattern, "!") && !strings.Contains(pattern, "/") {
			if matched, _ := filepath.Match(pattern, filepath.Base(path)); matched {
				return true
			}
		}
	}
	return false
}

func (s syncRun) requireCleanIncompleteCheckout() error {
	top, err := s.a.output("git", "-C", s.local, "rev-parse", "--show-toplevel")
	if err != nil || filepath.Clean(strings.TrimSpace(top)) != s.local {
		return fmt.Errorf("refusing unmanaged mirror %s: checkout identity is not exact", s.local)
	}
	common, err := s.a.output("git", "-C", s.local, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil || filepath.Clean(strings.TrimSpace(common)) != filepath.Join(s.repo, ".git") {
		return fmt.Errorf("refusing unmanaged mirror %s: checkout is not owned by %s", s.local, s.repo)
	}
	branch, err := s.a.output("git", "-C", s.local, "branch", "--show-current")
	if err != nil || strings.TrimSpace(branch) != s.vmbranch {
		return fmt.Errorf("refusing unmanaged mirror %s: expected branch %s", s.local, s.vmbranch)
	}
	head, err := s.a.output("git", "-C", s.local, "rev-parse", "HEAD")
	if err != nil || strings.TrimSpace(head) != s.vmhead {
		return fmt.Errorf("refusing unmanaged mirror %s: expected HEAD %s", s.local, prefix(s.vmhead, 11))
	}
	status, err := s.a.output("git", "-C", s.local, "status", "--porcelain")
	if err != nil || strings.TrimSpace(status) != "" {
		return fmt.Errorf("refusing unmanaged mirror %s: local changes require explicit repair", s.local)
	}
	return nil
}

func (s syncRun) requireManaged() error {
	managed, err := s.managedSession()
	if err != nil {
		return err
	}
	if !managed {
		return fmt.Errorf("refusing unmanaged mirror %s: expected Mutagen session %s", s.local, s.name)
	}
	return nil
}

func (s syncRun) managedSession() (bool, error) {
	text, err := s.a.combined(s.mutagen, "sync", "list", "--template", "{{ json . }}")
	if err != nil {
		return false, fmt.Errorf("cannot inspect Mutagen sessions: %w", err)
	}
	var sessions []mutagenListing
	if json.Unmarshal([]byte(text), &sessions) != nil {
		return false, fmt.Errorf("cannot verify Mutagen ownership for %s", s.name)
	}
	matches := sessions[:0]
	for _, session := range sessions {
		if session.Name == s.name {
			matches = append(matches, session)
		}
	}
	if len(matches) == 0 {
		return false, nil
	}
	if len(matches) != 1 {
		return false, fmt.Errorf("multiple Mutagen sessions matched %s", s.name)
	}
	if err := s.validateMutagenIdentity(matches[0]); err != nil {
		return false, err
	}
	return true, nil
}

func (s syncRun) validateMutagenIdentity(session mutagenListing) error {
	if session.Alpha.Protocol != "ssh" || session.Alpha.User != s.a.user || session.Alpha.Host != s.a.host || filepath.Clean(session.Alpha.Path) != s.vmwt || session.Beta.Protocol != "local" || filepath.Clean(session.Beta.Path) != s.local {
		return fmt.Errorf("Mutagen session %s has mismatched endpoints; refusing to modify it", s.name)
	}
	for _, pattern := range session.Ignore.Paths {
		if pattern == "bazel-*" {
			return fmt.Errorf("Mutagen session %s has unsafe unanchored bazel-* ignore; repair stale paths explicitly before syncing", s.name)
		}
	}
	return nil
}

func (s syncRun) ensureMutagen() error {
	managed, err := s.managedSession()
	if err != nil {
		return err
	}
	if managed {
		s.a.say("resume verified sync …")
		if err := s.a.quiet(nil, s.mutagen, "sync", "resume", s.name); err != nil {
			return fmt.Errorf("Mutagen resume failed for %s", s.name)
		}
	} else {
		s.a.say("create sync (two-way-resolved, VM wins) …")
		args := []string{"sync", "create", "--name=" + s.name, "--sync-mode=two-way-resolved", "--watch-polling-interval=600"}
		for _, ignore := range mutagenIgnores {
			args = append(args, "--ignore="+ignore)
		}
		args = append(args, s.a.user+"@"+s.a.host+":"+s.vmwt, s.local)
		if err := s.a.quiet(nil, s.mutagen, args...); err != nil {
			return fmt.Errorf("Mutagen create failed for %s", s.name)
		}
	}
	if err := s.a.quiet(nil, s.mutagen, "sync", "flush", s.name); err != nil {
		return fmt.Errorf("Mutagen synchronization failed for %s", s.name)
	}
	return s.requireReadyMutagen()
}

func (s syncRun) requireReadyMutagen() error {
	text, err := s.a.combined(s.mutagen, "sync", "list", "--template", "{{ json . }}")
	if err != nil {
		return fmt.Errorf("cannot verify Mutagen readiness: %w", err)
	}
	var sessions []mutagenListing
	if json.Unmarshal([]byte(text), &sessions) != nil {
		return fmt.Errorf("cannot verify Mutagen readiness for %s", s.name)
	}
	for _, session := range sessions {
		if session.Name != s.name {
			continue
		}
		if err := s.validateMutagenIdentity(session); err != nil {
			return err
		}
		if session.Paused || session.Status != "watching" || !session.Alpha.Connected || !session.Alpha.Scanned || !session.Beta.Connected || !session.Beta.Scanned {
			return fmt.Errorf("Mutagen session %s is not ready: status=%s paused=%t alpha-connected=%t alpha-scanned=%t beta-connected=%t beta-scanned=%t", s.name, session.Status, session.Paused, session.Alpha.Connected, session.Alpha.Scanned, session.Beta.Connected, session.Beta.Scanned)
		}
		return nil
	}
	return fmt.Errorf("Mutagen session %s disappeared after synchronization", s.name)
}

var mutagenIgnores = []string{
	".git", "node_modules", ".devenv", ".direnv", ".wrangler", ".envrc.local", ".env.local", ".env", "*.sqlite", "*.sqlite-shm", "*.sqlite-wal",
	".next", ".turbo", "target", "dist", "__pycache__", ".venv", "/bazel-*", "*.log", "*.png", "*.jpg",
	"*.jpeg", "*.gif", "*.webp", "*.ico", "*.icns", "*.pdf", "*.mp4", "*.woff", "*.woff2", "*.ttf", "!.heidr-pastes/**",
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
	return a.quietIn("", env, name, args...)
}
func (a app) quietIn(dir string, env []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir, cmd.Env, cmd.Stdout, cmd.Stderr = dir, commandEnv(env), io.Discard, io.Discard
	return cmd.Run()
}

func commandEnv(extra []string) []string { return append(os.Environ(), extra...) }
func executable(home, name string) (string, error) {
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	path := filepath.Join("/etc/profiles/per-user", filepath.Base(home), "bin", name)
	if isFile(path) {
		return path, nil
	}
	return "", fmt.Errorf("%s is unavailable", name)
}
func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
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

type silentError struct{}

func (silentError) Error() string { return "" }
