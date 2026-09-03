package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var testBinary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "desktopctl-test-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	testBinary = filepath.Join(dir, "desktopctl")
	cmd := exec.Command("go", "build", "-o", testBinary, ".")
	if output, err := cmd.CombinedOutput(); err != nil {
		panic(string(output))
	}
	os.Exit(m.Run())
}

func TestMainErrors(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{"no command", nil, "usage: desktopctl"},
		{"unknown command", []string{"unknown"}, "unknown command"},
		{"jump usage", []string{"niri-jump-or-exec"}, jumpUsage},
	} {
		t.Run(test.name, func(t *testing.T) {
			cmd := exec.Command(testBinary, test.args...)
			output, err := cmd.CombinedOutput()
			if err == nil || !strings.Contains(string(output), test.want) {
				t.Fatalf("output %q, error %v; want failure containing %q", output, err, test.want)
			}
		})
	}
}
