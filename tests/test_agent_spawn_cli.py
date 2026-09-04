#!/usr/bin/env python3
import json, os, socket, subprocess, tempfile, threading, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "dotfiles/bin/.local/bin/agent"
REMOTE = "/home/david_karlsson_lovable_dev/src/lovable.daphen-every-2563-message-only"


def fake_agentd(path, messages, ready):
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path)); server.listen(2); ready.set()
    while not messages:
        conn, _ = server.accept()
        try:
            conn.sendall(b'{"type":"roster","sessions":[]}\n')
            data = conn.recv(65536)
            if data: messages.append(json.loads(data.split(b"\n", 1)[0]))
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
    server.close()


class AgentSpawnCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.home = Path(self.tmp.name)
        self.runtime = self.home / "run"; self.runtime.mkdir()
        self.ssh = self.home / "ssh"
        self.ssh.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >"$SSH_LOG"\nexit "${SSH_EXIT:-0}"\n')
        self.ssh.chmod(0o755); self.log = self.home / "ssh.log"
        unit = self.home / ".config/systemd/user/agentd-work-tunnel.service"
        unit.parent.mkdir(parents=True)
        unit.write_text(f"[Service]\nExecStart={self.ssh} -N -o ConnectTimeout=15 -L %t/agentd-work.sock:127.0.0.1:17840 david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net\n")
        self.env = os.environ | {"HOME": str(self.home), "XDG_RUNTIME_DIR": str(self.runtime), "SSH_LOG": str(self.log)}
        for key in ("COCKPIT_AGENT_NAME", "COCKPIT_AGENT_PROFILE", "COCKPIT_AGENT_PARENT"):
            self.env.pop(key, None)

    def tearDown(self): self.tmp.cleanup()

    def spawn(self, directory=REMOTE, scope="work", ssh_exit="0"):
        args = [AGENT, "spawn", directory, "--name", "every-2563-message-only",
                "--profile", "lovable-worker", "--scope", scope]
        return subprocess.run(args, env=self.env | {"SSH_EXIT": ssh_exit}, capture_output=True, text=True, timeout=10)

    def test_valid_remote_dir_sends_seedless_root_spawn(self):
        messages, ready = [], threading.Event()
        thread = threading.Thread(target=fake_agentd, args=(self.runtime / "agentd-work.sock", messages, ready), daemon=True)
        thread.start(); ready.wait(2)
        result = self.spawn(); thread.join(8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(messages, [{"type": "spawn", "session": "every-2563-message-only",
                                     "cwd": REMOTE, "profile": "lovable-worker"}])
        args = self.log.read_text().splitlines()
        self.assertNotIn("-N", args); self.assertNotIn("-L", args)
        self.assertEqual(args[-2:], ["david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net",
                                    f"test -d {REMOTE}"])

    def test_remote_missing_error_and_local_missing_fail_closed(self):
        for code, text in (("1", "not a remote directory"), ("255", "validation failed (ssh exit 255)")):
            with self.subTest(ssh=code):
                result = self.spawn(ssh_exit=code)
                self.assertEqual(result.returncode, 1); self.assertIn(text, result.stderr)
        self.log.unlink(missing_ok=True)
        result = self.spawn(str(self.home / "missing"), "personal")
        self.assertEqual(result.returncode, 1); self.assertIn("not a directory", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__": unittest.main()
