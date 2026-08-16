#!/usr/bin/env python3
import importlib.util
import importlib.machinery
import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class FakeAgentd:
    def __init__(self, path: Path, sessions=None):
        self.path = path
        self.sessions = sessions or []
        self.messages = []
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(self.path))
        server.listen(1)
        self.ready.set()
        conn, _ = server.accept()
        conn.sendall((json.dumps({"type": "roster", "sessions": self.sessions}) + "\n").encode())
        buf = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line:
                    self.messages.append(json.loads(line))
        conn.close(); server.close()

    def start(self):
        self.thread.start(); self.ready.wait(2)

    def join(self):
        self.thread.join(8)
        if self.thread.is_alive(): raise AssertionError("fake agentd did not finish")


class LauncherPayloadTests(unittest.TestCase):
    def test_vm_wt_spawns_worker_with_plan_seed(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td); runtime = tmp / "run"; runtime.mkdir()
            fake = FakeAgentd(runtime / "agentd-work.sock"); fake.start()
            bindir = tmp / "bin"; bindir.mkdir()
            (bindir / "ssh").write_text("#!/bin/sh\nexit 0\n")
            (bindir / "ssh").chmod(0o755)
            localbin = tmp / ".local/bin"; localbin.mkdir(parents=True)
            (localbin / "vm-sync").write_text("#!/bin/sh\nexit 0\n")
            (localbin / "vm-sync").chmod(0o755)
            env = os.environ | {"HOME": td, "XDG_RUNTIME_DIR": str(runtime), "PATH": f"{bindir}:{os.environ['PATH']}"}
            subprocess.run([ROOT / "dotfiles/niri/.config/niri/scripts/vm-wt", "EVERY-1234"], env=env, check=True, capture_output=True, text=True, timeout=20)
            fake.join()
            spawn = next(m for m in fake.messages if m.get("type") == "spawn")
            self.assertEqual(spawn["profile"], "lovable-worker")
            self.assertEqual(spawn["prompt"], "/skill:plan-ticket EVERY-1234")

    def test_agent_review_spawns_reviewer_with_review_seed(self):
        script = ROOT / "dotfiles/niri/.config/niri/scripts/agent-review"
        loader = importlib.machinery.SourceFileLoader("agent_review", str(script))
        spec = importlib.util.spec_from_loader("agent_review", loader)
        module = importlib.util.module_from_spec(spec); loader.exec_module(module)
        left, right = socket.socketpair()
        module.agentd_connect = lambda: left
        module.start_rail_session("review-pr-77", Path("/tmp/review"), "/review-pr 77")
        payload = json.loads(right.recv(65536).split(b"\n", 1)[0])
        right.close()
        self.assertEqual(payload["profile"], "lovable-reviewer")
        self.assertEqual(payload["prompt"], "/review-pr 77")

    def test_orchestrator_seed_spawns_orchestrator(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td); runtime = tmp / "run"; runtime.mkdir()
            harness = tmp / "personal/notes/storage/references/orchestrator-harness.md"
            harness.parent.mkdir(parents=True); harness.write_text("harness")
            (tmp / "work/lovable").mkdir(parents=True)
            fake = FakeAgentd(runtime / "agentd-lovable.sock"); fake.start()
            env = os.environ | {"HOME": td, "XDG_RUNTIME_DIR": str(runtime)}
            subprocess.run([ROOT / "dotfiles/bin/.local/bin/orchestrator-seed"], env=env, check=True, capture_output=True, text=True, timeout=10)
            fake.join()
            self.assertEqual(fake.messages[0]["profile"], "lovable-orchestrator")
            self.assertEqual(fake.messages[1]["type"], "prompt")

    def test_watch_pr_is_the_only_watcher_skill(self):
        skills = ROOT / "dotfiles/ai/skills"
        text = (skills / "watch-pr/SKILL.md").read_text()
        self.assertIn("`name`: `watch-pr-<number>`", text)
        self.assertIn("`profile`: `lovable-watcher`", text)
        self.assertIn("agent_schedule_self", text)
        self.assertIn("agent_stop_self", text)
        self.assertNotIn("sleep 300", text)
        self.assertFalse((skills / "babysit-pr").exists())

    def test_reviewer_and_watcher_never_foreground_wait(self):
        roles = ROOT / "dotfiles/ai/roles"
        reviewer = (roles / "lovable-reviewer.md").read_text()
        watcher = (roles / "lovable-watcher.md").read_text()
        self.assertIn("repository-supported auto-merge", reviewer)
        self.assertIn("make one attempt", reviewer)
        self.assertIn("Never use `--watch`, `sleep`", reviewer)
        self.assertIn("roster must remain idle between checks", watcher)
        self.assertIn("Never use `sleep`, `--watch`", watcher)
        agents_extension = (ROOT / "dotfiles/ai/pi-extensions/agents/index.ts").read_text()
        self.assertIn('name: "agent_schedule_self"', agents_extension)
        self.assertIn('name: "agent_stop_self"', agents_extension)


if __name__ == "__main__":
    unittest.main()
