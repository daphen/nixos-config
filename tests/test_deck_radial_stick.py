import math
import os
from pathlib import Path
import selectors
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BWRAP = shutil.which("bwrap") or next(Path("/nix/store").glob("*-bubblewrap-*/bin/bwrap"), None)
HELPER = ROOT / "dotfiles/hyprland/.config/hypr/scripts/deck-radial-stick"


class DeckRadialStickTest(unittest.TestCase):
    def test_left_stick_on_second_controller(self):
        self.check_reader("left", 1)

    def test_left_stick_on_first_controller(self):
        self.check_reader("left", 0)

    def test_right_stick(self):
        self.check_reader("right", 1)

    def check_reader(self, stick, active):
        if not BWRAP:
            self.skipTest("requires bubblewrap")
        with tempfile.TemporaryDirectory(prefix="deck-radial-stick-") as directory:
            root = Path(directory)
            (root / "dev").mkdir()
            (root / "sys/class/hidraw").mkdir(parents=True)
            pipes = []
            for number in (4, 5):
                name = f"hidraw{number}"
                device = root / "sys/devices/virtual" / name
                device.mkdir(parents=True)
                (device / "uevent").write_text("HID_ID=0003:000028DE:000012F0\n")
                entry = root / "sys/class/hidraw" / name
                entry.mkdir()
                (entry / "device").symlink_to(f"/sys/devices/virtual/{name}")
                pipe = root / "dev" / name
                os.mkfifo(pipe)
                pipes.append(os.open(pipe, os.O_RDWR | os.O_NONBLOCK))
            command = [str(BWRAP), "--die-with-parent", "--ro-bind", "/", "/",
                       "--ro-bind", str(root / "sys"), "/sys", "--bind", str(root / "dev"), "/dev",
                       str(HELPER), stick]
            reader = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            poller = selectors.DefaultSelector()
            poller.register(reader.stdout, selectors.EVENT_READ)
            try:
                offset = 48 if stick == "left" else 52

                def packet(x=0, y=0):
                    data = bytearray(64)
                    data[:3] = bytes((1, 0, 9))
                    struct.pack_into("<hh", data, offset, x, y)
                    return data

                for pipe in pipes:
                    os.write(pipe, packet())
                self.assertFalse(poller.select(.03), "neutral controller emitted a direction")
                invalid = packet(30000, 0)
                invalid[0] = 0
                os.write(pipes[active], invalid)
                self.assertFalse(poller.select(.03), "invalid report header emitted a direction")
                for sample in range(128):
                    angle = sample * math.tau / 128
                    x, y = round(math.sin(angle) * 30000), round(math.cos(angle) * 30000)
                    os.write(pipes[1 - active], packet())
                    os.write(pipes[active], packet(x, y))
                    self.assertTrue(poller.select(2), f"no direction for controller {active}, sample {sample}")
                    line = reader.stdout.readline().decode().strip()
                    self.assertTrue(line.startswith("direction "), line)
                    self.assertAlmostEqual(float(line.split()[1]), sample / 16, places=3)
                    os.write(pipes[active], packet(x, y))
                    self.assertFalse(poller.select(.005), "unchanged axes bypassed deduplication")
                os.write(pipes[active], packet(100, 100))
                self.assertFalse(poller.select(.05), "deadzone emitted a direction")
                os.close(pipes[1 - active])
                pipes[1 - active] = None
                os.write(pipes[active], packet(30000, 0))
                self.assertTrue(poller.select(2), "remaining controller stopped after other device EOF")
                self.assertEqual(reader.stdout.readline(), b"direction 2.000000\n")
                os.close(pipes[active])
                pipes[active] = None
                self.assertEqual(reader.wait(timeout=2), 0, "last device EOF did not exit cleanly")
            finally:
                if reader.poll() is None:
                    reader.terminate()
                _, errors = reader.communicate(timeout=3)
                poller.close()
                for pipe in pipes:
                    if pipe is not None:
                        os.close(pipe)
            self.assertEqual(errors, b"")


if __name__ == "__main__":
    unittest.main()
