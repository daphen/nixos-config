package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
)

func main() {
	args := os.Args[1:]
	var err error
	switch {
	case len(args) >= 1 && args[0] == "picker" && (len(args) == 1 || len(args) == 2 && args[1] == "--id-only"):
		err = runPicker(len(args) == 2, os.Stdout, os.Stderr)
	case len(args) == 3 && args[0] == "preview":
		err = runPreview(args[1], args[2], os.Stdout, os.Stderr)
	default:
		err = fmt.Errorf("usage: sessionctl <picker [--id-only]|preview LINE META_FILE>")
	}
	if err != nil {
		if _, silent := err.(silentError); !silent {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}

type silentError struct{}

func (silentError) Error() string { return "" }

func runDetached(session sessionRow) {
	cmd := exec.Command("setsid", "-f", "kitty", "--class", "claude", "--working-directory", session.cwd, "-e", "claude", "--resume", session.id)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, io.Discard, io.Discard
	if cmd.Start() == nil {
		_ = cmd.Process.Release()
	}
}
