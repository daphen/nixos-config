#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "dotfiles/niri/.config/niri/scripts"


class DesktopctlLauncherTests(unittest.TestCase):
    def test_wrappers_route_to_go(self):
        cases = {
            "browser-dispatch": ("browser-dispatch", SCRIPTS / "browser-config.sh"),
            "notification-dispatch": ("notification-dispatch", SCRIPTS),
            "niri-jump-or-exec": ("niri-jump-or-exec", None),
            "launch-mail-client": ("launch-mail-client", None),
        }
        with tempfile.TemporaryDirectory() as directory:
            bindir = Path(directory) / "bin"
            bindir.mkdir()
            log = Path(directory) / "log"
            fake = bindir / "desktopctl"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$LOG\"\nprintf '%s' \"${BROWSER_CONFIG:-}${NIRI_SCRIPTS_DIR:-}\" >> \"$LOG\"\n")
            fake.chmod(0o755)
            env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}", "LOG": str(log)}
            for name, (command, expected_path) in cases.items():
                subprocess.run([SCRIPTS / name, "one", "two"], env=env, check=True, timeout=10)
                lines = log.read_text().splitlines()
                self.assertEqual(lines[0], f"{command} one two")
                if expected_path is not None:
                    self.assertEqual(lines[1], str(expected_path))
                self.assertLessEqual(len((SCRIPTS / name).read_text().splitlines()), 5)
                self.assertNotIn(".bash", (SCRIPTS / name).read_text())


if __name__ == "__main__":
    unittest.main()
