#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "dotfiles/themes/.config/themes/theme-manager.sh"
THEMES = WRAPPER.parent


class ThemeManagerLauncherTests(unittest.TestCase):
    def test_ignores_legacy_theme_manager_shim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            marker = root / "legacy-ran"
            legacy = bindir / "theme-manager"
            legacy.write_text(f"#!/bin/sh\ntouch {marker}\nexit 9\n")
            legacy.chmod(0o755)
            themectl = bindir / "themectl"
            themectl.write_text("#!/bin/sh\nexit 0\n")
            themectl.chmod(0o755)
            env = os.environ | {
                "HOME": str(root),
                "PATH": f"{bindir}:/run/current-system/sw/bin",
            }
            result = subprocess.run(
                [WRAPPER, "status"], env=env, capture_output=True, text=True, timeout=10
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())

    def test_routes_to_themectl_with_themes_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            result_file = root / "result"
            binary = bindir / "themectl"
            binary.write_text(
                "#!/bin/sh\nprintf '%s\\n%s\\n' \"$*\" \"$THEMES_DIR\" > \"$RESULT\"\n"
            )
            binary.chmod(0o755)
            env = os.environ | {
                "PATH": f"{bindir}:/run/current-system/sw/bin",
                "RESULT": str(result_file),
            }
            subprocess.run([WRAPPER, "toggle"], env=env, check=True, timeout=10)
            self.assertEqual(result_file.read_text().splitlines(), ["toggle", str(THEMES)])


if __name__ == "__main__":
    unittest.main()
