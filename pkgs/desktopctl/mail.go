package main

import (
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type mailWindow struct {
	Title string `json:"title"`
	PID   int    `json:"pid"`
}

type mailUI struct {
	pid   int
	start uint64
}

func runMail() error {
	home, user := os.Getenv("HOME"), os.Getenv("USER")
	os.Setenv("QML2_IMPORT_PATH", home+"/.local/share/qml")
	os.Setenv("QT_QPA_PLATFORMTHEME", "xdgdesktopportal")
	os.Setenv("PATH", strings.Join([]string{
		home + "/.local/bin",
		"/etc/profiles/per-user/" + user + "/bin",
		"/run/current-system/sw/bin",
		os.Getenv("PATH"),
	}, ":"))
	current := mailExecutable("mlqs")
	for _, pid := range mailPIDsByComm("mlqs") {
		exe, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
		if err == nil && current != "" && exe != current {
			if mailSignal(pid, syscall.SIGTERM) == nil {
				mailWaitAndKill(pid)
			}
		}
	}
	currentUI := ""
	if current != "" {
		currentUI = filepath.Join(filepath.Dir(filepath.Dir(current)), "share/mlqs/ui")
	}
	uis, seen := mailUIPIDs(), make(map[int]bool)
	for _, pid := range uis {
		seen[pid] = true
	}
	for _, pid := range mailWindowPIDs("mlqs") {
		if !seen[pid] {
			uis = append(uis, pid)
		}
	}
	keep := 0
	for _, pid := range uis {
		if mailAlive(pid) && currentUI != "" && mailUIConfig(pid) == currentUI {
			keep = pid
		}
	}
	for _, pid := range uis {
		if pid != keep && mailAlive(pid) {
			_ = mailSignal(pid, syscall.SIGTERM)
		}
	}
	if mailSummon() == nil {
		for range 12 {
			if mailHasWindow("mlqs") {
				return nil
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	windowPIDs := make(map[int]bool)
	for _, window := range mailWindows() {
		if window.PID != 0 {
			windowPIDs[window.PID] = true
		}
	}
	for _, pid := range mailUIPIDs() {
		if !windowPIDs[pid] {
			_ = mailSignal(pid, syscall.SIGTERM)
		}
	}
	return mailExecClient()
}

func mailExecutable(name string) string {
	path, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return ""
	}
	return path
}

func mailPIDsByComm(want string) []int {
	entries, _ := os.ReadDir("/proc")
	var pids []int
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		comm, err := os.ReadFile("/proc/" + entry.Name() + "/comm")
		if err == nil && strings.TrimSpace(string(comm)) == want {
			pids = append(pids, pid)
		}
	}
	return pids
}

func mailSignal(pid int, signal syscall.Signal) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(signal)
}

func mailAlive(pid int) bool { return mailSignal(pid, 0) == nil }

func mailWaitAndKill(pid int) {
	for range 50 {
		if !mailAlive(pid) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = mailSignal(pid, syscall.SIGKILL)
}

func mailUIConfig(pid int) string {
	root := "/proc/" + strconv.Itoa(pid)
	data, err := os.ReadFile(root + "/cmdline")
	if err != nil {
		return ""
	}
	args := strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
	for i := 0; i+1 < len(args); i++ {
		if args[i] != "-p" {
			continue
		}
		if filepath.IsAbs(args[i+1]) {
			return strings.TrimSuffix(args[i+1], "/")
		}
		cwd, err := os.Readlink(root + "/cwd")
		if err != nil {
			return ""
		}
		return strings.TrimSuffix(cwd+"/"+args[i+1], "/")
	}
	return ""
}

func mailUIPIDs() []int {
	entries, _ := os.ReadDir("/proc")
	var found []mailUI
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		comm, err := os.ReadFile("/proc/" + entry.Name() + "/comm")
		if err != nil || !strings.Contains(strings.TrimSpace(string(comm)), "quickshell") {
			continue
		}
		if cfg := mailUIConfig(pid); !strings.HasSuffix(cfg, "mlqs/ui") {
			continue
		}
		stat, err := os.ReadFile("/proc/" + entry.Name() + "/stat")
		if err != nil {
			continue
		}
		end := strings.LastIndexByte(string(stat), ')')
		fields := strings.Fields(string(stat)[end+1:])
		if end < 0 || len(fields) < 20 {
			continue
		}
		start, err := strconv.ParseUint(fields[19], 10, 64)
		if err == nil {
			found = append(found, mailUI{pid, start})
		}
	}
	sort.SliceStable(found, func(i, j int) bool {
		return found[i].start < found[j].start
	})
	pids := make([]int, len(found))
	for i := range found {
		pids[i] = found[i].pid
	}
	return pids
}

func mailWindows() []mailWindow {
	data, _ := commandOutput("niri", "msg", "--json", "windows")
	var windows []mailWindow
	_ = json.Unmarshal(data, &windows)
	return windows
}

func mailWindowPIDs(title string) []int {
	var pids []int
	for _, window := range mailWindows() {
		if window.Title == title && window.PID != 0 {
			pids = append(pids, window.PID)
		}
	}
	return pids
}

func mailSummon() error {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		return os.ErrNotExist
	}
	connection, err := net.DialTimeout("unix", filepath.Join(runtimeDir, "mlqs.sock"), 500*time.Millisecond)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(500 * time.Millisecond))
	_, err = connection.Write([]byte("{\"type\":\"summonui\"}\n"))
	return err
}

func mailHasWindow(title string) bool {
	for _, window := range mailWindows() {
		if window.Title == title {
			return true
		}
	}
	return false
}

func mailExecClient() error {
	log, err := os.OpenFile("/tmp/mlqs-ui.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o666)
	if err != nil {
		return err
	}
	defer log.Close()
	if err := syscall.Dup2(int(log.Fd()), int(os.Stdout.Fd())); err != nil {
		return err
	}
	if err := syscall.Dup2(int(log.Fd()), int(os.Stderr.Fd())); err != nil {
		return err
	}
	client, err := exec.LookPath("mlqs-client")
	if err != nil {
		return commandStatus{code: 127, err: err}
	}
	if err := syscall.Exec(client, []string{"mlqs-client"}, os.Environ()); err != nil {
		return commandStatus{code: 126, err: err}
	}
	return nil
}
