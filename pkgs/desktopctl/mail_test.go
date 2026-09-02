package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

type mailDesktop struct {
	dir, home, result, windows string
	children                   []*exec.Cmd
	pipes                      []*os.File
}

func newMailDesktop(t *testing.T) *mailDesktop {
	t.Helper()
	if len(mailPIDsByComm("mlqs")) != 0 || len(mailUIPIDs()) != 0 {
		t.Skip("host mlqs processes are running; refusing a destructive fixture test")
	}
	dir := t.TempDir()
	m := &mailDesktop{
		dir: dir, home: filepath.Join(dir, "home"),
		result: filepath.Join(dir, "result"), windows: filepath.Join(dir, "windows"),
	}
	bin := filepath.Join(m.home, ".local/bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(bin, "mlqs"), "#!"+bash+"\nexit 0\n")
	writeExecutable(t, filepath.Join(bin, "mlqs-client"), "#!"+bash+"\n"+`printf 'QML=%s
QT=%s
PATH=%s
ARGV=%s
' "$QML2_IMPORT_PATH" "$QT_QPA_PLATFORMTHEME" "$PATH" "$*" > "$MAIL_RESULT"
`)
	writeExecutable(t, filepath.Join(bin, "niri"), "#!"+bash+"\n"+`if [[ "$*" == "msg --json windows" ]]; then printf '%s' "$(<"$MAIL_WINDOWS")"; else printf '[]'; fi
`)
	if err := os.WriteFile(m.windows, []byte("[]"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, child := range m.children {
			if child.Process != nil {
				_ = child.Process.Signal(syscall.SIGKILL)
			}
		}
		for _, pipe := range m.pipes {
			_ = pipe.Close()
		}
	})
	return m
}

func (m *mailDesktop) env(extra ...string) []string {
	return append(os.Environ(), append([]string{
		"HOME=" + m.home,
		"USER=fixture",
		"PATH=" + m.dir,
		"XDG_RUNTIME_DIR=" + m.dir,
		"MAIL_RESULT=" + m.result,
		"MAIL_WINDOWS=" + m.windows,
	}, extra...)...)
}

func (m *mailDesktop) fixture(t *testing.T, comm string, args ...string) *exec.Cmd {
	t.Helper()
	dir := filepath.Join(m.dir, fmt.Sprintf("fixture-%d", len(m.children)))
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, comm)
	if err := os.Symlink(bash, path); err != nil {
		t.Fatal(err)
	}
	all := append([]string{"-c", "read -r", "--"}, args...)
	cmd := exec.Command(path, all...)
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stdin = reader
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	_ = reader.Close()
	m.children = append(m.children, cmd)
	m.pipes = append(m.pipes, writer)
	go func() { _ = cmd.Wait() }()
	return cmd
}

func (m *mailDesktop) assertOnlyOwned(t *testing.T) {
	t.Helper()
	owned := make(map[int]bool)
	for _, child := range m.children {
		owned[child.Process.Pid] = true
	}
	for _, pid := range append(mailPIDsByComm("mlqs"), mailUIPIDs()...) {
		if !owned[pid] {
			t.Skipf("process %d appeared after fixture setup; refusing to signal it", pid)
		}
	}
}

func (m *mailDesktop) run(t *testing.T) []byte {
	t.Helper()
	m.assertOnlyOwned(t)
	cmd := exec.Command(testBinary, "launch-mail-client")
	cmd.Env = m.env()
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("launch-mail-client: %v: %s", err, output)
	}
	result, err := os.ReadFile(m.result)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestMailColdLaunchReapsOnlyOwnedFixtures(t *testing.T) {
	m := newMailDesktop(t)
	currentUI := filepath.Join(m.home, ".local/share/mlqs/ui")
	oldUI := filepath.Join(m.dir, "old/mlqs/ui")
	first := m.fixture(t, "fake-quickshell", "-p", currentUI)
	time.Sleep(20 * time.Millisecond)
	keep := m.fixture(t, "fake-quickshell", "-p", currentUI)
	staleUI := m.fixture(t, "fake-quickshell", "-p", oldUI)
	orphan := m.fixture(t, "mail-orphan")
	staleDaemon := m.fixture(t, "mlqs")
	windows := fmt.Sprintf(`[{"title":"mlqs","pid":%d},{"title":"mlqs","pid":%d}]`, keep.Process.Pid, orphan.Process.Pid)
	if err := os.WriteFile(m.windows, []byte(windows), 0o600); err != nil {
		t.Fatal(err)
	}

	result := string(m.run(t))
	for name, process := range map[string]*exec.Cmd{
		"older current UI": first, "stale UI": staleUI,
		"window orphan": orphan, "stale daemon": staleDaemon,
	} {
		if waitAlive(process.Process.Pid, time.Second) {
			t.Errorf("%s process %d survived", name, process.Process.Pid)
		}
	}
	if !waitAlive(keep.Process.Pid, 0) {
		t.Errorf("last current UI %d was killed", keep.Process.Pid)
	}
	for _, want := range []string{
		"QML=" + filepath.Join(m.home, ".local/share/qml"),
		"QT=xdgdesktopportal",
		"PATH=" + filepath.Join(m.home, ".local/bin") + ":/etc/profiles/per-user/fixture/bin:/run/current-system/sw/bin:" + m.dir,
		"ARGV=",
	} {
		if !strings.Contains(result, want) {
			t.Errorf("result %q does not contain %q", result, want)
		}
	}
}

func TestMailWarmSummonWaitsForWindow(t *testing.T) {
	m := newMailDesktop(t)
	listener, err := net.Listen("unix", filepath.Join(m.dir, "mlqs.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	payload := make(chan string, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		line, _ := bufio.NewReader(connection).ReadString('\n')
		_ = connection.Close()
		_ = os.WriteFile(m.windows, []byte(`[{"title":"mlqs","pid":123}]`), 0o600)
		payload <- line
	}()
	m.assertOnlyOwned(t)
	cmd := exec.Command(testBinary, "launch-mail-client")
	cmd.Env = m.env()
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("warm launch: %v: %s", err, output)
	}
	select {
	case got := <-payload:
		if got != "{\"type\":\"summonui\"}\n" {
			t.Errorf("payload = %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("summon payload not received")
	}
	if _, err := os.Stat(m.result); !os.IsNotExist(err) {
		t.Errorf("cold client ran during warm summon: %v", err)
	}
}

func waitAlive(pid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Kill(pid, 0)
		if err != nil {
			return false
		}
		if timeout == 0 || time.Now().After(deadline) {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
}
