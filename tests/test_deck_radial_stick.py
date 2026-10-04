#!/usr/bin/env python3
import contextlib
import importlib.machinery
import importlib.util
import io
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "dotfiles/hyprland/.config/hypr/scripts/deck-radial-stick"
CAPTURED_AXES = ((169, 32767), (32767, -83), (42, -32767), (-32767, 0))


def load_helper():
    loader = importlib.machinery.SourceFileLoader("deck_radial_stick", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class DeckRadialStickTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = load_helper()

    def run_reports(self, axes):
        with tempfile.NamedTemporaryFile() as stream:
            for x, y in axes:
                report = bytearray(64)
                report[:3] = bytes((1, 0, 9))
                struct.pack_into("<hh", report, 52, x, y)
                stream.write(report)
            stream.flush()
            self.helper.find_controller = lambda: Path(stream.name)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.helper.main()
        return output.getvalue().splitlines()

    def test_captured_cardinals_and_fractional_angle(self):
        axes = [(0, 0)]
        for sample in CAPTURED_AXES:
            axes.extend((sample, (0, 0)))
        axes.extend(((32767, 17679), (0, 0)))
        directions = [float(line.split()[1]) for line in self.run_reports(axes)]
        self.assertEqual(len(directions), 5)
        for actual, expected in zip(directions, (0, 2, 4, 6, 1.370034)):
            self.assertAlmostEqual(actual, expected, delta=0.01)

    def test_center_no_data_and_duplicate_report(self):
        self.assertEqual(self.run_reports([]), [])
        self.assertEqual(self.run_reports([(0, 0), (1000, -1000)]), [])
        self.assertEqual(len(self.run_reports([CAPTURED_AXES[1]] * 2)), 1)


if __name__ == "__main__":
    unittest.main()
