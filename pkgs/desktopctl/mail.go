package main

import (
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
	daemons, uis := mailProcesses()
	killedDaemon := false
	for _, pid := range daemons {
		exe, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
		if err != nil || current == "" || exe == current {
			continue
		}
		if mailSignal(pid, syscall.SIGTERM) == nil {
			killedDaemon = true
			mailWaitAndKill(pid)
		}
	}
	if killedDaemon {
		_, uis = mailProcesses()
	}
	currentUI := ""
	if current != "" {
		currentUI = filepath.Join(filepath.Dir(filepath.Dir(current)), "share/mlqs/ui")
	}
	seen := make(map[int]bool)
	for _, pid := range uis {
		seen[pid] = true
	}
	windows, _ := niriWindows()
	for _, window := range windows {
		if window.Title == "mlqs" && window.PID != 0 && !seen[window.PID] {
			uis = append(uis, window.PID)
		}
	}
	keep := 0
	for i := len(uis) - 1; i >= 0; i-- {
		pid := uis[i]
		if currentUI != "" && mailAlive(pid) && mailUIConfig(pid) == currentUI {
			keep = pid
			break
		}
	}
	for _, pid := range uis {
		if pid != keep {
			_ = mailSignal(pid, syscall.SIGTERM)
		}
	}
	if mailSummon() == nil {
		var found bool
		windows, found = mailWaitForWindow("mlqs")
		if found {
			return nil
		}
	} else {
		windows, _ = niriWindows()
	}
	windowPIDs := make(map[int]bool)
	for _, window := range windows {
		if window.PID != 0 {
			windowPIDs[window.PID] = true
		}
	}
	_, uis = mailProcesses()
	for _, pid := range uis {
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

func mailSignal(pid int, signal syscall.Signal) error {
	return syscall.Kill(pid, signal)
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

func mailProcesses() ([]int, []int) {
	entries, _ := os.ReadDir("/proc")
	var daemons []int
	var found []mailUI
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		root := "/proc/" + entry.Name()
		data, err := os.ReadFile(root + "/comm")
		if err != nil {
			continue
		}
		comm := strings.TrimSpace(string(data))
		if comm == "mlqs" {
			daemons = append(daemons, pid)
		}
		if !strings.Contains(comm, "quickshell") || !strings.HasSuffix(mailUIConfig(pid), "mlqs/ui") {
			continue
		}
		data, err = os.ReadFile(root + "/stat")
		if err != nil {
			continue
		}
		stat := string(data)
		end := strings.LastIndexByte(stat, ')')
		if end < 0 {
			continue
		}
		fields := strings.Fields(stat[end+1:])
		if len(fields) < 20 {
			continue
		}
		start, err := strconv.ParseUint(fields[19], 10, 64)
		if err == nil {
			found = append(found, mailUI{pid, start})
		}
	}
	sort.SliceStable(found, func(i, j int) bool { return found[i].start < found[j].start })
	uis := make([]int, len(found))
	for i, process := range found {
		uis[i] = process.pid
	}
	return daemons, uis
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

func mailWaitForWindow(title string) ([]niriWindow, bool) {
	var windows []niriWindow
	for range 12 {
		windows, _ = niriWindows()
		for _, window := range windows {
			if window.Title == title {
				return windows, true
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	windows, _ = niriWindows()
	return windows, false
}

func mailExecClient() error {
	log, err := os.OpenFile("/tmp/mlqs-ui.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o666)
	if err != nil {
		return err
	}
	defer log.Close()
	if err := redirectOutput(log); err != nil {
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
