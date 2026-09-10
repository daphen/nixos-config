#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "dotfiles/niri/.config/niri/scripts/launch-agentd"
NIRI_CONFIG = ROOT / "dotfiles/niri/.config/niri/config.kdl"


class LaunchAgentdTests(unittest.TestCase):
    def fixture(self, key):
        directory = tempfile.TemporaryDirectory()
        home = Path(directory.name)
        bindir = home / "bin"
        agentdir = home / ".local/bin"
        secrets = home / ".config/fish"
        bindir.mkdir()
        agentdir.mkdir(parents=True)
        secrets.mkdir(parents=True)
        (secrets / "secrets.fish").write_text("# fixture\n")
        scripts = {
            "secret-tool": "#!/bin/sh\nexit 1\n",
            "timeout": "#!/bin/sh\nshift\nexec \"$@\"\n",
            "fish": "#!/bin/sh\nprintf '%s' \"$FISH_KEY\"\n",
        }
        for name, body in scripts.items():
            path = bindir / name
            path.write_text(body)
            path.chmod(0o755)
        agent = agentdir / "agentd"
        agent.write_text("#!/bin/sh\n[ \"$OPENAI_API_KEY\" = test-key ] || exit 9\nprintf '%s\\n' \"$*\" > \"$LOG\"\n")
        agent.chmod(0o755)
        env = os.environ | {
            "HOME": str(home),
            "PATH": f"{bindir}:/bin:/usr/bin",
            "FISH_KEY": key,
            "LOG": str(home / "agent.log"),
        }
        return directory, home, env

    def test_locked_keyring_uses_existing_fish_secret(self):
        directory, home, env = self.fixture("test-key")
        with directory:
            subprocess.run([LAUNCHER, "lovable", "--repo", "/repo"], env=env, check=True, timeout=5)
            self.assertEqual((home / "agent.log").read_text(), "--scope lovable --repo /repo\n")

    def test_no_key_refuses_to_start_agentd(self):
        directory, home, env = self.fixture("")
        with directory:
            result = subprocess.run([LAUNCHER, "lovable"], env=env, text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no openai key available", result.stderr)
            self.assertFalse((home / "agent.log").exists())

    def test_niri_has_no_second_agentd_launch_path(self):
        config = NIRI_CONFIG.read_text()
        self.assertNotIn("agentd --scope", config)
        self.assertNotIn("launch-agentd-scope", config)


if __name__ == "__main__":
    unittest.main()
