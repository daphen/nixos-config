package main

import (
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

func commandOutput(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).Output()
}

func runCommand(stdout, stderr io.Writer, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

func startDetached(command string) {
	fields := strings.Fields(command)
	if len(fields) == 0 {
		return
	}
	cmd := exec.Command(fields[0], fields[1:]...)
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if cmd.Start() == nil {
		_ = cmd.Process.Release()
	}
}

func startBackground(command string) {
	fields := strings.Fields(command)
	if len(fields) == 0 {
		return
	}
	cmd := exec.Command(fields[0], fields[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if cmd.Start() == nil {
		_ = cmd.Process.Release()
	}
}

func runVisible(name string, args ...string) error {
	return runCommand(os.Stdout, os.Stderr, name, args...)
}
