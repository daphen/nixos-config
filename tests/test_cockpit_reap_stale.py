import os
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path


REAPER = Path(__file__).parents[1] / "dotfiles/niri/.config/niri/scripts/cockpit-reap-stale"


class CockpitReapStaleTests(unittest.TestCase):
    def test_pauses_abandoned_legacy_sync_without_touching_live_ticket(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "mutagen.log"
            (bin_dir / "agent").write_text("#!/bin/sh\necho 'personal idle coding every-2447 /home/me/work/lovable.every-2447'\n")
            (bin_dir / "pgrep").write_text("#!/bin/sh\nexit 1\n")
            (bin_dir / "mutagen").write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = 'sync list' ]; then\n"
                "  printf 'Name: lovbox-heidr\\nName: vmwt-every-2447\\n'\n"
                "else\n"
                "  printf '%s\\n' \"$*\" >> \"$MUTAGEN_LOG\"\n"
                "fi\n"
            )
            for command in ("agent", "pgrep", "mutagen"):
                (bin_dir / command).chmod(0o755)
            runtime = root / "runtime"
            runtime.mkdir()
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(runtime / "agentd-test.sock"))
            try:
                env = os.environ | {
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "XDG_RUNTIME_DIR": str(runtime),
                    "MUTAGEN_LOG": str(log),
                }
                result = subprocess.run([REAPER, "--yes"], env=env, text=True, capture_output=True, check=True)
            finally:
                listener.close()
            self.assertIn("paused stale legacy sync lovbox-heidr", result.stdout)
            self.assertEqual(log.read_text().splitlines(), ["sync pause lovbox-heidr"])


if __name__ == "__main__":
    unittest.main()
