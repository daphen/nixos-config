import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BWRAP = shutil.which("bwrap") or next(Path("/nix/store").glob("*-bubblewrap-*/bin/bwrap"), None)


class DeckRadialSelectionTest(unittest.TestCase):
    def test_single_analog_packet_changes_selection(self):
        self.run_fixture(False, 8)

    def test_dense_rotation(self):
        self.run_fixture(True, 8)

    def test_single_window_ring(self):
        self.run_fixture(False, 1)

    def test_empty_window_ring(self):
        self.run_fixture(False, 0)

    def run_fixture(self, dense_only, client_count):
        qs = os.environ.get("QS_BIN") or shutil.which("qs")
        if not qs or not BWRAP:
            self.skipTest("requires Quickshell and bubblewrap")
        with tempfile.TemporaryDirectory(prefix="deck-radial-selection-") as directory:
            root = Path(directory)
            home, runtime, bin_dir = root / "home", root / "runtime", root / "bin"
            for path in (home, runtime, bin_dir):
                path.mkdir(mode=0o700)
            scripts = home / ".config/hypr/scripts"
            scripts.mkdir(parents=True)
            for name in ("deck-radial-stick", "desktop-launch", "hypr-dispatch"):
                path = scripts / name
                path.write_text("#!/bin/sh\n" + ("printf 'direction 2.125\\n'\n" if name == "deck-radial-stick" else "exit 0\n"))
                path.chmod(0o755)
            config_dir = root / "config"
            shutil.copytree(ROOT / "dotfiles/quickshell/.config/quickshell", config_dir)
            config = config_dir / "check.qml"
            shutil.copyfile(ROOT / "tests/deck-radial-selection.qml", config)
            (home / ".config/quickshell").symlink_to(config_dir)
            clients = [{"title": f"App {i}", "class": "org.quickshell", "address": hex(i + 16),
                        "mapped": True, "hidden": False} for i in range(client_count)]
            responses = {"clients": clients, "monitors": [], "workspaces": []}
            hyprctl = bin_dir / "hyprctl"
            hyprctl.write_text("#!/usr/bin/env python3\nimport json,sys\nresponses=" + repr(responses)
                               + "\nprint(json.dumps(responses.get(sys.argv[-1], [])))\n")
            hyprctl.chmod(0o755)
            env = dict(os.environ)
            for key in ("WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
                env.pop(key, None)
            env.update(HOME=str(home), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen",
                       QT_QUICK_BACKEND="software", QS_BIN=str(qs), RADIAL_TEST_CONFIG=str(config),
                       RADIAL_DENSE_ONLY="1" if dense_only else "0", RADIAL_TEST_CLIENT_COUNT=str(client_count),
                       PATH=str(bin_dir) + ":" + env["PATH"])
            result = subprocess.run(
                [str(BWRAP), "--die-with-parent", "--unshare-net", "--unshare-pid", "--ro-bind", "/", "/",
                 "--proc", "/proc", "--dev-bind", "/dev", "/dev", "--tmpfs", "/tmp",
                 "--bind", str(root), str(root), "dbus-run-session", "--", str(qs), "--no-color", "-p", str(config)],
                env=env, capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("FAIL ", output)
            self.assertIn("PASS radial public IPC and analog packets", output)


if __name__ == "__main__":
    unittest.main()
