#!/usr/bin/env python3
import os
import pty
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BWRAP = shutil.which("bwrap") or next(Path("/nix/store").glob("*-bubblewrap-*/bin/bwrap"), None)


@unittest.skipUnless(BWRAP, "bubblewrap is required to isolate session commands")
class HyprSessionTests(unittest.TestCase):
    def launch(self, niri_active, canvas_exit=0, name="hypr-session", graphical=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            launcher = root / "experiments/hyprland-canvas/run-login"
            launcher.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "experiments/hyprland-canvas/run-login", launcher)
            (root / "pkgs/desktopctl").mkdir(parents=True)
            bindir = root / "bin"
            bindir.mkdir()
            (bindir / name).symlink_to(launcher)
            package = root / ".cache/hyprland-canvas-dev/validated"
            scripts = {
                bindir / "tty": "echo /dev/tty2",
                bindir / "loginctl": "echo tty",
                bindir / "systemctl": '''printf 'systemctl %s\n' "$*" >> "$CALL_LOG"
case "$*" in *is-active*) exit "$NIRI_STATUS";; esac''',
                bindir / "pkill": 'echo pkill >> "$CALL_LOG"',
                bindir / "go": "exit 0",
                bindir / "nix": f"echo {package}",
                package / "bin/Hyprland": "exit 0",
                package / "bin/start-hyprland": '''printf 'canvas mode=%s\n' "$HYPR_CANVAS_REAL" >> "$CALL_LOG"
exit "$CANVAS_EXIT"''',
                root / "dotfiles/hyprland/.config/hypr/scripts/quickshell-session-stop":
                    'echo quickshell-stop >> "$CALL_LOG"',
            }
            for path, body in scripts.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            gpu = root / "gpu"
            gpu.touch()
            log = root / "calls"
            env = os.environ | {
                "HOME": directory, "PATH": f"{bindir}:{os.environ['PATH']}",
                "CALL_LOG": str(log), "NIRI_STATUS": "0" if niri_active else "3",
                "CANVAS_EXIT": str(canvas_exit), "XDG_SESSION_ID": "test",
            }
            for key in ("WAYLAND_DISPLAY", "HYPRLAND_CANVAS_DEV_ROOT", "XDG_CACHE_HOME"):
                env.pop(key, None)
            if graphical:
                env["WAYLAND_DISPLAY"] = "test-wayland"
            master, slave = pty.openpty()
            try:
                os.write(master, b"n\n")
                result = subprocess.run([
                    str(BWRAP), "--ro-bind", "/", "/", "--tmpfs", "/tmp", "--bind", directory, directory,
                    "--dev", "/dev", "--dir", "/dev/dri/by-path", "--ro-bind", str(gpu),
                    "/dev/dri/by-path/pci-0000:65:00.0-card", "--", str(bindir / name),
                ], env=env, stdin=slave, capture_output=True, text=True, timeout=10)
            finally:
                os.close(master)
                os.close(slave)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_standalone_session_and_legacy_alias(self):
        for name in ("hypr-session", "hypr-real"):
            with self.subTest(name=name):
                result, calls = self.launch(False, name=name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, ["systemctl --user is-active --quiet niri.service", "canvas mode=1"])

    def test_handoff_restores_only_the_existing_niri_session(self):
        for active in (False, True):
            for status in (0, 7):
                with self.subTest(active=active, status=status):
                    result, calls = self.launch(active, status)
                    self.assertEqual(result.returncode, status, result.stderr)
                    expected = ["systemctl --user is-active --quiet niri.service"]
                    if active:
                        expected += ["quickshell-stop", "systemctl --user stop niri.service", "pkill"]
                    expected += ["canvas mode=1"]
                    if active:
                        expected += ["systemctl --user start niri.service"]
                    self.assertEqual(calls, expected)

    def test_graphical_launch_is_rejected_without_touching_services(self):
        result, calls = self.launch(True, graphical=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Run this from a Linux TTY", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
