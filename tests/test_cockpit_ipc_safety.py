#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IpcSafety(unittest.TestCase):
    def test_failed_display_probe_does_not_delete_a_live_instance(self):
        for desktop in ["hyprland/.config/hypr", "niri/.config/niri"]:
            with self.subTest(desktop=desktop), tempfile.TemporaryDirectory(prefix="cockpit-ipc-safety-") as tmp:
                root = Path(tmp)
                runtime = root / "runtime"
                runtime.mkdir(mode=0o700)
                (root / "shell.qml").write_text('''import Quickshell
import Quickshell.Io
ShellRoot {
    IpcHandler {
        target: "cockpit"
        function nvimSock(): string { return "/isolated-editor.sock" }
        function pane(): string { return "rail" }
    }
}
''')
                env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen", WAYLAND_DISPLAY="wayland-isolated-producer", COCKPIT_NVIM_SOCK="/isolated-editor.sock")
                env.pop("DISPLAY", None)
                with (root / "qs.log").open("w") as log:
                    child = subprocess.Popen(["qs", "-p", tmp], env=env, stdout=log, stderr=log)
                    try:
                        instances = []
                        for _ in range(50):
                            result = subprocess.run(["qs", "list", "-a", "--json"], env=env, capture_output=True, text=True)
                            if result.stdout.strip().startswith("["):
                                instances = json.loads(result.stdout)
                            if instances:
                                break
                            time.sleep(0.05)
                        self.assertEqual(len(instances), 1, (root / "qs.log").read_text())
                        identity = instances[0]["id"]
                        ipc = ["qs", "ipc", "-i", identity, "call", "cockpit", "pane"]
                        for _ in range(50):
                            ready = subprocess.run(ipc, env=env, capture_output=True, text=True)
                            if ready.stdout.strip() == "rail":
                                break
                            time.sleep(0.05)
                        self.assertEqual(ready.stdout.strip(), "rail")
                        caller = dict(env)
                        caller.pop("WAYLAND_DISPLAY")
                        rejected = subprocess.run(ipc, env=caller, capture_output=True, text=True)
                        self.assertNotEqual(rejected.returncode, 0, "fixture must reproduce a display-mismatched IPC failure")
                        script = ROOT / "dotfiles" / desktop / "scripts/cockpit-ipc"
                        subprocess.run(["bash", str(script), "pane"], env=caller, capture_output=True, text=True, timeout=8)
                        self.assertIsNone(child.poll(), "the real isolated instance must remain alive")
                        self.assertTrue((runtime / "quickshell/by-id" / identity / "ipc.sock").exists(), "lookup deleted a live IPC socket")
                        self.assertEqual(subprocess.run(ipc, env=env, capture_output=True, text=True).stdout.strip(), "rail")
                    finally:
                        child.terminate()
                        child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
