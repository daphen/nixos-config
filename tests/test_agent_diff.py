import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "dotfiles/bin/.local/bin/agent"
class Agentd:
    def __init__(self, response):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "agentd-vm.sock"
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(str(self.path))
        self.sock.listen()
        self.response = response
        self.request = None
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
    def serve(self):
        conn, _ = self.sock.accept()
        with conn:
            conn.sendall((json.dumps({"type": "roster", "sessions": [
                {"id": "session-1", "name": "worker", "cwd": "/vm/rebased"}
            ]}) + "\n").encode())
        conn, _ = self.sock.accept()
        with conn:
            data = b""
            while b"\n" not in data:
                data += conn.recv(65536)
            self.request = json.loads(data.split(b"\n", 1)[0])
            payload = dict(self.response)
            payload["id"] = self.request["id"]
            conn.sendall((json.dumps(payload) + "\n").encode())
    def close(self):
        self.thread.join(timeout=2)
        self.sock.close()
        self.tmp.cleanup()
class AgentDiffTests(unittest.TestCase):
    def run_diff(self, daemon):
        env = os.environ | {
            "XDG_RUNTIME_DIR": daemon.tmp.name,
            "HOME": daemon.tmp.name,
            "AGENT_DIFF_TIMEOUT": "0.2",
            "AGENT_ROSTER_TIMEOUT": "0.2",
        }
        return subprocess.run(
            [str(AGENT), "diff", "--scope", "vm", "worker"],
            text=True, capture_output=True, env=env, timeout=2,
        )
    def test_prints_authoritative_rebased_snapshot_unchanged(self):
        snapshot = {
            "type": "changes", "session": "session-1", "cwd": "/vm/rebased",
            "head": "vm-head-after-rebase", "base": "vm-merge-base", "branch": "ticket",
            "files": [
                {"path": "renamed.txt", "oldPath": "old.txt", "add": 3, "del": 1,
                 "binary": False, "untracked": False, "patch": "diff --git a/old.txt b/renamed.txt\n+vm truth"},
                {"path": "asset.bin", "add": 0, "del": 0, "binary": True,
                 "untracked": True, "patch": ""},
            ],
            "diff": "canonical VM diff", "error": "",
        }
        daemon = Agentd(snapshot)
        try:
            result = self.run_diff(daemon)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output["head"], "vm-head-after-rebase")
            self.assertEqual(output["files"], snapshot["files"])
            self.assertEqual(daemon.request["type"], "get_changes")
            self.assertEqual(daemon.request["session"], "session-1")
            self.assertEqual(set(daemon.request), {"type", "session", "id"})
        finally:
            daemon.close()
    def test_error_json_is_printed_and_fails(self):
        daemon = Agentd({"type": "changes", "session": "session-1", "error": "HEAD moved"})
        try:
            result = self.run_diff(daemon)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["error"], "HEAD moved")
        finally:
            daemon.close()
if __name__ == "__main__":
    unittest.main()
