package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func (a app) syncDrafts() error {
	if a.nativeVM() {
		return fmt.Errorf("draft mirroring must run on the desktop")
	}
	mutagen, err := executable(a.home, "mutagen")
	if err != nil {
		return err
	}
	name := "vm-notes-inbox"
	remote := "/home/" + a.user + "/personal/notes/storage/inbox"
	local := filepath.Join(a.home, "work", "vm-notes", "inbox")
	state := filepath.Join(a.home, ".local", "state", "cockpit")
	if err := os.MkdirAll(state, 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(state, name+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("draft synchronization is already running: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	run := func(args ...string) (string, error) {
		text, err := exec.CommandContext(ctx, mutagen, args...).CombinedOutput()
		return string(text), err
	}
	type listing struct {
		mutagenListing
		Mode      string
		Conflicts []json.RawMessage
	}
	inspect := func() (*listing, error) {
		text, err := run("sync", "list", "--template", "{{ json . }}")
		if err != nil {
			return nil, fmt.Errorf("cannot inspect draft mirror: %w", err)
		}
		var sessions []listing
		if err := json.Unmarshal([]byte(text), &sessions); err != nil {
			return nil, fmt.Errorf("cannot decode draft mirror status: %w", err)
		}
		var found *listing
		for i := range sessions {
			s := &sessions[i]
			if s.Name != name {
				continue
			}
			if found != nil {
				return nil, fmt.Errorf("multiple draft mirrors named %s; left untouched", name)
			}
			if s.Alpha.Protocol != "ssh" || s.Alpha.User != a.user || s.Alpha.Host != a.host || s.Alpha.Path != remote || s.Beta.Protocol != "local" || s.Beta.Path != local || s.Mode != "two-way-safe" || len(s.Ignore.Paths) != 0 {
				return nil, fmt.Errorf("draft mirror has mismatched endpoints or policy; left untouched")
			}
			found = s
		}
		return found, nil
	}
	session, err := inspect()
	if err != nil {
		return err
	}
	if session == nil {
		entries, err := os.ReadDir(local)
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		if len(entries) != 0 {
			return fmt.Errorf("unmanaged draft folder is not empty: %s; left untouched", local)
		}
		if err := os.MkdirAll(local, 0o700); err != nil {
			return err
		}
		text, err := run("sync", "create", "--name="+name, "--mode=two-way-safe", "--no-global-configuration", "--default-file-mode=0600", "--default-directory-mode=0700", a.user+"@"+a.host+":"+remote, local)
		if err != nil {
			return fmt.Errorf("cannot create draft mirror: %s: %w", strings.TrimSpace(text), err)
		}
	} else if session.Paused {
		if _, err := run("sync", "resume", name); err != nil {
			return fmt.Errorf("cannot resume draft mirror: %w", err)
		}
	}
	if text, err := run("sync", "flush", name); err != nil {
		return fmt.Errorf("cannot synchronize drafts: %s: %w", strings.TrimSpace(text), err)
	}
	session, err = inspect()
	if err != nil {
		return err
	}
	if session == nil || session.Paused || session.Status != "watching" || !session.Alpha.Connected || !session.Alpha.Scanned || !session.Beta.Connected || !session.Beta.Scanned {
		return fmt.Errorf("draft mirror is not ready; no file opened")
	}
	if len(session.Alpha.ScanProblems)+len(session.Alpha.TransitionProblems)+len(session.Beta.ScanProblems)+len(session.Beta.TransitionProblems) != 0 {
		return fmt.Errorf("draft mirror has file scanning or transfer errors; no file opened")
	}
	if len(session.Conflicts) != 0 {
		return fmt.Errorf("draft mirror has conflicting edits; both versions preserved, resolve with mutagen sync list --long %s", name)
	}
	fmt.Fprintln(a.out, local)
	return nil
}
