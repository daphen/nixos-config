#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NIRI = ROOT / "dotfiles/niri/.config/niri/scripts"


class GoCommandLauncherTests(unittest.TestCase):
    def test_every_launcher_routes_to_go_without_bash_fallback(self):
        cases = [
            (NIRI / "vm-sync", "vmctl", "sync one two", None),
            (NIRI / "vm-wt", "vmctl", "worktree one two", None),
            (NIRI / "vm-cockpit", "vmctl", "cockpit one two", None),
            (NIRI / "browser-dispatch", "desktopctl", "browser-dispatch one two", "BROWSER_CONFIG"),
            (NIRI / "notification-dispatch", "desktopctl", "notification-dispatch one two", "NIRI_SCRIPTS_DIR"),
            (NIRI / "niri-jump-or-exec", "desktopctl", "niri-jump-or-exec one two", None),
            (NIRI / "launch-mail-client", "desktopctl", "launch-mail-client one two", None),
            (NIRI / "spawn-claude-session-picker", "sessionctl", "picker one two", None),
            (NIRI / "claude-session-preview", "sessionctl", "preview one two", None),
            (ROOT / "dotfiles/qs-chat-clients/.config/qs-chat-clients/media-viewer.sh", "mediactl", "view one two", None),
            (ROOT / "dotfiles/themes/.config/themes/theme-manager.sh", "themectl", "one two", "THEMES_DIR"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            bindir = Path(directory) / "bin"
            bindir.mkdir()
            log = Path(directory) / "log"
            for binary in {case[1] for case in cases}:
                path = bindir / binary
                path.write_text("#!/bin/sh\nprintf '%s\\n%s\\n%s\\n' \"$*\" \"${BROWSER_CONFIG:-}${NIRI_SCRIPTS_DIR:-}${THEMES_DIR:-}\" \"$0\" > \"$LOG\"\n")
                path.chmod(0o755)
            env = os.environ | {"PATH": f"{bindir}:/run/current-system/sw/bin", "LOG": str(log)}
            for launcher, binary, expected_args, expected_env in cases:
                with self.subTest(launcher=launcher.name):
                    text = launcher.read_text()
                    self.assertNotIn(".bash", text)
                    self.assertIn(f"/bin/{binary}", text)
                    subprocess.run([launcher, "one", "two"], env=env, check=True, timeout=10)
                    args, routed_env, executable = log.read_text().splitlines()
                    self.assertEqual(args, expected_args)
                    self.assertEqual(Path(executable).name, binary)
                    if expected_env == "BROWSER_CONFIG":
                        self.assertEqual(routed_env, str(NIRI / "browser-config.sh"))
                    elif expected_env == "NIRI_SCRIPTS_DIR":
                        self.assertEqual(routed_env, str(NIRI))
                    elif expected_env == "THEMES_DIR":
                        self.assertEqual(routed_env, str(launcher.parent))
                    else:
                        self.assertEqual(routed_env, "")


if __name__ == "__main__":
    unittest.main()
