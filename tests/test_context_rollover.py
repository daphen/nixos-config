#!/usr/bin/env python3
import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = ROOT / "dotfiles/ai/pi-extensions"


@unittest.skipUnless(shutil.which("pi"), "requires the installed Pi runtime")
class ContextRolloverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="context-rollover-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        for name in ("run", "config", "cache", "data", "pi", "sessions"):
            (self.home / name).mkdir()
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(self.home),
            "XDG_RUNTIME_DIR": str(self.home / "run"),
            "XDG_CONFIG_HOME": str(self.home / "config"),
            "XDG_CACHE_HOME": str(self.home / "cache"),
            "XDG_DATA_HOME": str(self.home / "data"),
            "PI_CODING_AGENT_DIR": str(self.home / "pi"),
            "PI_CODING_AGENT_SESSION_DIR": str(self.home / "sessions"),
            "PI_OFFLINE": "1",
        }
        self.requests = []
        requests = self.requests

        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                tokens = [183_000, 184_000, 1_000][min(len(requests) - 1, 2)]
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                chunks = [
                    {"choices": [{"index": 0, "delta": {"role": "assistant", "content": "OK\n⟢ Kept the tested constraint."}, "finish_reason": None}]},
                    {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": tokens, "completion_tokens": 10, "total_tokens": tokens + 10}},
                ]
                for chunk in chunks:
                    self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        self.addCleanup(self.server.server_close)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.provider = self.home / "provider.ts"
        self.provider.write_text('''export default function(pi: any) {
  pi.registerProvider("rollover-test", {
    baseUrl: "http://127.0.0.1:PORT/v1", apiKey: "local-test", api: "openai-completions",
    models: [{ id: "large", name: "Large", reasoning: true, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 1050000, maxTokens: 16384 }]
  });
}
'''.replace("PORT", str(self.server.server_port)))

    def start(self, extensions, cwd, session=None):
        cwd.mkdir(parents=True, exist_ok=True)
        cmd = [shutil.which("pi"), "--mode", "rpc", "--no-extensions", "--no-skills",
               "--no-prompt-templates", "--model", "rollover-test/large", "--thinking", "medium",
               "--extension", str(self.provider)]
        for extension in extensions:
            cmd += ["--extension", str(extension)]
        if session:
            cmd += ["--session", session]
        stderr = (self.home / "stderr.log").open("a+")
        self.addCleanup(stderr.close)
        self.proc = subprocess.Popen(cmd, cwd=cwd, env=self.env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=stderr, text=True, bufsize=1)
        proc = self.proc

        def close():
            proc.stdin.close()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            proc.stdout.close()

        self.addCleanup(close)
        self.queue = queue.Queue()
        out = self.queue
        threading.Thread(target=lambda: [out.put(json.loads(line)) for line in proc.stdout], daemon=True).start()

    def command(self, kind, **values):
        self.proc.stdin.write(json.dumps({"type": kind, **values}) + "\n")
        self.proc.stdin.flush()
        while True:
            event = self.queue.get(timeout=20)
            if kind == "prompt" and event.get("type") == "agent_settled":
                return
            if event.get("type") == "response" and event.get("command") == kind:
                self.assertTrue(event["success"], event)
                if kind != "prompt":
                    return event.get("data", {})

    def check_rollover(self, extensions, cwd):
        self.start(extensions, cwd)
        before = self.command("get_state")
        self.assertEqual(before["model"]["contextWindow"], 200_000)
        self.assertEqual((before["model"]["id"], before["thinkingLevel"]), ("large", "medium"))
        session = Path(before["sessionFile"])
        self.command("prompt", message="FIRST-CONSTRAINT: preserve native identity. " + "a" * 100_000)
        self.assertFalse(any(json.loads(line).get("type") == "compaction" for line in session.read_text().splitlines()))
        self.command("prompt", message="SECOND-KEPT: continue the current task. " + "b" * 100_000)
        entries = [json.loads(line) for line in session.read_text().splitlines()]
        checkpoints = [entry for entry in entries if entry.get("type") == "compaction"]
        self.assertEqual(len(checkpoints), 1)
        checkpoint = checkpoints[0]
        self.assertTrue(checkpoint["fromHook"])
        self.assertEqual(checkpoint["details"]["strategy"], "deterministic-auto-v3")
        self.assertIn("FIRST-CONSTRAINT", checkpoint["summary"])
        self.assertIsNone(checkpoint.get("usage"))
        self.assertEqual(len(self.requests), 2, "checkpoint must not call the provider")
        self.command("prompt", message="Continue after the checkpoint.")
        self.assertIn("Recovery checkpoint", json.dumps(self.requests[-1]))
        self.assertIn("SECOND-KEPT", json.dumps(self.requests[-1]))
        after = self.command("get_state")
        self.assertEqual(after["sessionId"], before["sessionId"])
        self.assertEqual(after["sessionFile"], before["sessionFile"])
        self.assertEqual(after["model"], before["model"])
        self.assertEqual(after["thinkingLevel"], before["thinkingLevel"])
        self.proc.stdin.close()
        self.proc.wait(timeout=10)
        self.assertEqual(self.proc.returncode, 0)
        self.start(extensions, cwd, str(session))
        resumed = self.command("get_state")
        self.assertEqual(resumed["model"], before["model"])
        self.assertEqual(resumed["thinkingLevel"], before["thinkingLevel"])
        self.assertEqual(resumed["sessionId"], before["sessionId"])
        self.assertEqual(resumed["sessionFile"], before["sessionFile"])
        self.assertIn("Recovery checkpoint", json.dumps(self.command("get_messages")))

    def test_cockpit_uses_native_threshold_and_retains_identity(self):
        self.check_rollover([EXTENSIONS / "nixos-rollover/index.ts"], self.home / "personal/ai-cockpit")

    def test_worker_manifest_loads_the_same_policy(self):
        manifest = ROOT / "dotfiles/ai/roles/manifest.json"
        worker = json.loads(manifest.read_text())["profiles"]["lovable-worker"]
        extensions = [manifest.parent / value for value in worker["extensions"] if "/scoped/" in value]
        self.check_rollover(extensions, self.home / "src/lovable-every-1")


if __name__ == "__main__":
    unittest.main()
