import os
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path


REAPER = Path(__file__).parents[1] / "dotfiles/niri/.config/niri/scripts/cockpit-reap-stale"


class CockpitReapStaleTests(unittest.TestCase):
    def test_stops_stale_ticket_stack_without_touching_live_ticket(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            live_dir = root / "lovable.every-2447"
            stale_dir = root / "lovable.every-9"
            live_dir.mkdir()
            stale_dir.mkdir()
            live = subprocess.Popen(["sleep", "30"], cwd=live_dir)
            stale = subprocess.Popen(["sleep", "30"], cwd=stale_dir)
            try:
                (bin_dir / "agent").write_text("#!/bin/sh\necho 'personal idle coding every-2447 /home/me/work/lovable.every-2447'\n")
                (bin_dir / "pgrep").write_text(f"#!/bin/sh\nprintf '%s\\n' {live.pid} {stale.pid}\n")
                for command in ("agent", "pgrep"):
                    (bin_dir / command).chmod(0o755)
                runtime = root / "runtime"
                runtime.mkdir()
                listener = socket.socket(socket.AF_UNIX)
                listener.bind(str(runtime / "agentd-test.sock"))
                try:
                    env = os.environ | {"PATH": f"{bin_dir}:{os.environ['PATH']}", "XDG_RUNTIME_DIR": str(runtime)}
                    result = subprocess.run([REAPER, "--yes"], env=env, text=True, capture_output=True, check=True)
                finally:
                    listener.close()
                self.assertIn(f"stopped devenv stack {stale.pid}", result.stdout)
                self.assertNotEqual(stale.wait(timeout=5), 0)
                self.assertIsNone(live.poll())
            finally:
                live.kill()
                stale.kill()
                live.wait()
                stale.wait()


if __name__ == "__main__":
    unittest.main()
