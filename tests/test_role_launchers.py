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
from types import SimpleNamespace
from typing import Any
from unittest import mock

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
            try:
                chunk = conn.recv(65536)
            except ConnectionResetError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line:
                    message = json.loads(line)
                    self.messages.append(message)
                    if message.get("type") == "spawn":
                        session = {key: message[key] for key in ("session", "cwd", "profile")}
                        session["name"] = session.pop("session")
                        conn.sendall((json.dumps({"type": "roster", "sessions": [session]}) + "\n").encode())
        conn.close(); server.close()

    def start(self):
        self.thread.start(); self.ready.wait(2)

    def join(self):
        self.thread.join(8)
        if self.thread.is_alive(): raise AssertionError("fake agentd did not finish")


class VmSliceReaperOwnershipTests(unittest.TestCase):
    def setUp(self):
        script = ROOT / "dotfiles/niri/.config/niri/scripts/vm-slice-reaper"
        loader = importlib.machinery.SourceFileLoader(f"vm_slice_reaper_{self._testMethodName}", str(script))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        self.reaper: Any = importlib.util.module_from_spec(spec)
        loader.exec_module(self.reaper)
        self.reaper.SRC = "/vm/src"
        self.reaper.DRY = False

    def run_reaper(self, live, running, argv):
        stopped = []
        completed = SimpleNamespace(stdout="", stderr="", returncode=0)
        with mock.patch.object(self.reaper, "roster", return_value=live), \
             mock.patch.object(self.reaper, "slice_dirs", return_value=set(running)), \
             mock.patch.object(self.reaper, "stop_slice", side_effect=lambda worktree: stopped.append(worktree) or True), \
             mock.patch.object(self.reaper.time, "sleep"), \
             mock.patch.object(self.reaper.subprocess, "run", return_value=completed), \
             mock.patch.object(self.reaper.sys, "argv", argv):
            self.assertEqual(self.reaper.main(), 0)
        return stopped

    def test_sweep_keeps_long_cwd_owned_by_short_session_name(self):
        worktree = "lovable.davidkarlsson-every-2739-fit-ds-canvas"
        live = {"every-2739": {"name": "every-2739", "cwd": f"/vm/src/{worktree}", "status": "streaming"}}
        self.assertEqual(self.run_reaper(live, [worktree], ["vm-slice-reaper"]), [])

    def test_hook_keeps_slice_when_alias_stops_but_primary_owner_remains(self):
        worktree = "lovable.davidkarlsson-every-2739-fit-ds-canvas"
        live = {"every-2739": {"name": "every-2739", "cwd": f"/vm/src/{worktree}", "status": "idle"}}
        argv = ["vm-slice-reaper", "--worktree", f"/vm/src/{worktree}", "--session", "long-alias"]
        self.assertEqual(self.run_reaper(live, [worktree], argv), [])

    def test_sweep_reaps_true_orphan(self):
        worktree = "lovable-every-9999"
        live = {"other": {"name": "other", "cwd": "/vm/src/lovable-every-1", "status": "streaming"}}
        self.assertEqual(self.run_reaper(live, [worktree], ["vm-slice-reaper"]), [worktree])

    def test_unavailable_roster_fails_closed_for_sweep_and_hook(self):
        worktree = "lovable-every-9999"
        self.assertEqual(self.run_reaper(None, [worktree], ["vm-slice-reaper"]), [])
        argv = ["vm-slice-reaper", "--worktree", f"/vm/src/{worktree}", "--session", "every-9999"]
        self.assertEqual(self.run_reaper(None, [worktree], argv), [])


class LauncherPayloadTests(unittest.TestCase):
    def test_vm_wt_spawns_worker_with_plan_seed(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td); runtime = tmp / "run"; runtime.mkdir()
            fake = FakeAgentd(runtime / "agentd-work.sock"); fake.start()
            bindir = tmp / "bin"; bindir.mkdir()
            subprocess.run(
                ["go", "build", "-o", bindir / "vmctl", "."],
                cwd=ROOT / "pkgs/vmctl", check=True, timeout=60,
            )
            head = "0123456789abcdef0123456789abcdef01234567"
            (bindir / "ssh").write_text(f"#!/bin/sh\nprintf '%s\\n' '{head}'\n")
            (bindir / "ssh").chmod(0o755)
            (bindir / "git").write_text(f"#!/bin/sh\nprintf '%s\\n' '{head}'\n")
            (bindir / "git").chmod(0o755)
            localbin = tmp / ".local/bin"; localbin.mkdir(parents=True)
            (localbin / "vm-sync").write_text(
                "#!/bin/sh\n"
                "ticket=$(printf '%s' \"$1\" | tr '[:upper:]' '[:lower:]')\n"
                "mkdir -p \"$HOME/work/lovable.daphen-$ticket/.git\"\n"
            )
            (localbin / "vm-sync").chmod(0o755)
            env = os.environ | {"HOME": td, "XDG_RUNTIME_DIR": str(runtime), "PATH": f"{bindir}:{os.environ['PATH']}"}
            result = subprocess.run([ROOT / "dotfiles/niri/.config/niri/scripts/vm-wt", "EVERY-1234"], env=env, check=False, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("agent context was preserved", result.stdout)
            fake.join()
            spawn = next(m for m in fake.messages if m.get("type") == "spawn")
            self.assertEqual(spawn["profile"], "lovable-worker")
            self.assertEqual(spawn["prompt"], "/skill:plan-ticket EVERY-1234")

    def test_agent_review_spawns_reviewer_with_review_seed_and_waits_for_roster(self):
        script = ROOT / "dotfiles/niri/.config/niri/scripts/agent-review"
        loader = importlib.machinery.SourceFileLoader("agent_review", str(script))
        spec = importlib.util.spec_from_loader("agent_review", loader)
        assert spec is not None
        module: Any = importlib.util.module_from_spec(spec); loader.exec_module(module)
        left, right = socket.socketpair()
        module.agentd_connect = lambda: left
        payloads = []

        def acknowledge():
            payloads.append(json.loads(right.recv(65536).split(b"\n", 1)[0]))
            right.sendall((json.dumps({"type": "roster", "sessions": [{
                "id": "review-pr-77", "name": "review-pr-77", "cwd": "/tmp/review",
            }]}) + "\n").encode())
            right.close()

        responder = threading.Thread(target=acknowledge)
        responder.start()
        module.start_rail_session("review-pr-77", Path("/tmp/review"), "/review-pr 77")
        responder.join(2)
        self.assertFalse(responder.is_alive())
        self.assertEqual(payloads[0]["profile"], "lovable-reviewer")
        self.assertEqual(payloads[0]["prompt"], "/review-pr 77")

    def test_agent_review_surfaces_agentd_spawn_error(self):
        script = ROOT / "dotfiles/niri/.config/niri/scripts/agent-review"
        loader = importlib.machinery.SourceFileLoader("agent_review_error", str(script))
        spec = importlib.util.spec_from_loader("agent_review_error", loader)
        assert spec is not None
        module: Any = importlib.util.module_from_spec(spec); loader.exec_module(module)
        left, right = socket.socketpair()
        module.agentd_connect = lambda: left

        def reject():
            right.recv(65536)
            right.sendall(b'{"type":"error","session":"review-pr-77","error":"spawn refused"}\n')
            right.close()

        responder = threading.Thread(target=reject)
        responder.start()
        notifications = []
        module.notify = notifications.append
        with self.assertRaisesRegex(SystemExit, "spawn refused"):
            module.start_rail_session("review-pr-77", Path("/tmp/review"), "/review-pr 77")
        responder.join(2)
        self.assertEqual(notifications, ["review failed: spawn refused"])

    def test_agent_cli_forwards_runtime_contract_to_canonical_launcher(self):
        script = ROOT / "dotfiles/bin/.local/bin/agent"
        loader = importlib.machinery.SourceFileLoader("agent_cli", str(script))
        spec = importlib.util.spec_from_loader("agent_cli", loader)
        assert spec is not None
        module: Any = importlib.util.module_from_spec(spec); loader.exec_module(module)
        args = SimpleNamespace(
            teardown=None, pr="83188", devenv=False,
            manual_test="project-id", browser_profile_seed="/tmp/stopped-profile",
            runtime_contract="exact-branch", allow_sandbox_start=True,
        )
        with mock.patch.object(module.os, "execv") as execv:
            module.cmd_review(args)
        forwarded = execv.call_args.args[1]
        self.assertIn("--runtime-contract", forwarded)
        self.assertEqual(forwarded[forwarded.index("--runtime-contract") + 1], "exact-branch")
        self.assertIn("--allow-sandbox-start", forwarded)

    def test_agent_cli_parser_accepts_runtime_contract(self):
        result = subprocess.run(
            [ROOT / "dotfiles/bin/.local/bin/agent", "review", "--help"],
            check=True, capture_output=True, text=True, timeout=10,
        )
        self.assertIn("--runtime-contract {production,exact-branch}", result.stdout)

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
        reviewer = " ".join((roles / "lovable-reviewer.md").read_text().split())
        watcher = " ".join((roles / "lovable-watcher.md").read_text().split())
        self.assertIn("repository-supported auto-merge", reviewer)
        self.assertIn("make one attempt", reviewer)
        self.assertIn("Never use `--watch`, `sleep`", reviewer)
        self.assertIn("remain idle between checks", watcher)
        self.assertIn("Never sleep, `--watch`", watcher)
        agents_extension = (ROOT / "dotfiles/ai/pi-extensions/agents/index.ts").read_text()
        self.assertIn('name: "agent_schedule_self"', agents_extension)
        self.assertIn('name: "agent_stop_self"', agents_extension)


if __name__ == "__main__":
    unittest.main()
