import json
import os
import resource
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "dotfiles/bin/.local/bin/pi-to-vault"


class PiToVaultCLITest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.sessions = self.home / ".pi/agent/sessions/test"
        self.sessions.mkdir(parents=True)
        bin_dir = self.home / ".local/bin"
        bin_dir.mkdir(parents=True)
        self.bin_dir = bin_dir
        pi = bin_dir / "pi"
        pi.write_text(
            '#!/bin/sh\nprintf "called\\n" >> "$HOME/calls"\n'
            'printf "%s\\n" "$@" > "$HOME/args"\n'
            'cat > "$HOME/input"\n'
            'if [ "$FAIL_CONDENSE" = 1 ]; then echo authentication_failed >&2; exit 1; fi\n'
            'printf "## Goal\\nCondensed\\n"\n'
        )
        pi.chmod(0o755)

    def session(self, name, sid, age=3600):
        path = self.sessions / f"{name}.jsonl"
        path.write_text(
            json.dumps({"cwd": str(self.home / "personal/project"), "id": sid}) + "\n"
            + json.dumps({"message": {"role": "user", "content": "hello"}}) + "\n"
        )
        stamp = time.time() - age
        os.utime(path, (stamp, stamp))
        return path

    def run_cli(self, **env):
        return subprocess.run(
            ["python3", str(SCRIPT), "--no-push"],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin_dir}:{os.environ['PATH']}", **env},
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )

    def test_skips_old_active_and_unchanged_before_condensing(self):
        self.session("old", "old-12345", age=32 * 86400)
        self.session("active", "active-12345", age=30)
        unchanged = self.session("unchanged", "same-12345")
        dest = self.home / "personal/notes/storage/sessions/project-same-123.md"
        dest.parent.mkdir(parents=True)
        dest.write_text("existing")
        os.utime(dest, (unchanged.stat().st_mtime + 1,) * 2)
        self.session("eligible", "new-12345")

        result = self.run_cli()
        self.assertIn("condensed 1 finished session(s)", result.stdout)
        self.assertEqual((self.home / "calls").read_text().splitlines(), ["called"])
        args = (self.home / "args").read_text().splitlines()
        for flag in ("-p", "--model", "openai/gpt-6-sol", "--no-session", "--no-tools",
                     "--no-extensions", "--no-skills", "--no-context-files", "--no-approve"):
            self.assertIn(flag, args)
        self.assertIn("## you\nhello", (self.home / "input").read_text())
        self.assertTrue((dest.parent / "project-new-1234.md").exists())
        self.run_cli()
        self.assertEqual((self.home / "calls").read_text().splitlines(), ["called"])

    def test_active_large_transcript_does_not_need_memory_for_its_contents(self):
        path = self.session("active-large", "active-large")
        with path.open("ab") as source:
            source.truncate(128 * 1024 * 1024)
        result = subprocess.run(
            ["python3", str(SCRIPT), "--no-push"],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin_dir}:{os.environ['PATH']}"},
            capture_output=True,
            text=True,
            timeout=10,
            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024,) * 2),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("condensed 0 finished session(s)", result.stdout)
        self.assertFalse((self.home / "calls").exists())

    def test_one_condensation_failure_defers_remaining_sessions(self):
        self.session("first", "first-12345")
        self.session("second", "second-12345")
        result = self.run_cli(FAIL_CONDENSE="1")
        self.assertIn("condensation unavailable; remaining sessions deferred", result.stdout)
        self.assertIn("condensed 0 finished session(s)", result.stdout)
        self.assertEqual((self.home / "calls").read_text().splitlines(), ["called"])
        self.assertFalse((self.home / "personal/notes/storage/sessions").exists())


if __name__ == "__main__":
    unittest.main()
