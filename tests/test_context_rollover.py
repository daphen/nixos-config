#!/usr/bin/env python3
import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from datetime import datetime, timezone
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
            "PI_OFFLINE": "1", "TYPESAFEAI_API_KEY": "synthetic-test-key",
        }
        self.requests = []
        self.jev_requests = []
        self.jev_mode = "valid"
        self.jev_delay = 0
        self.jev_started = threading.Event()
        self.estimate_tokens = False
        self.forced_tokens = None
        self.overflow_once = False
        self.overflow_sent = False
        owner = self

        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == "/jev":
                    owner.jev_requests.append((dict(self.headers), payload))
                    owner.jev_started.set()
                    if owner.jev_delay:
                        time.sleep(owner.jev_delay)
                    answers = {key: {"noul": 0.01} for key in payload.get("questions", {})}
                    if owner.jev_mode == "partial" and answers:
                        answers.pop(next(iter(answers)))
                    elif owner.jev_mode == "outofrange" and answers:
                        answers[next(iter(answers))] = {"noul": 2}
                    body = {"model": "jev-test", "answers": answers,
                            "usage": {"input_tokens": 123, "output_tokens": 7}}
                    encoded = b"not json" if owner.jev_mode == "invalid" else json.dumps(body).encode()
                    try:
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(encoded)
                    except BrokenPipeError:
                        pass
                    return
                owner.requests.append(payload)
                if owner.overflow_once and not owner.overflow_sent:
                    owner.overflow_sent = True
                    encoded = json.dumps({"error": {"code": "context_length_exceeded",
                        "type": "invalid_request_error", "message": "maximum context length exceeded"}}).encode()
                    self.send_response(400)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
                if owner.forced_tokens is not None:
                    tokens = owner.forced_tokens
                elif owner.estimate_tokens:
                    tokens = (len(json.dumps(payload.get("messages", []), ensure_ascii=False).encode()) + 3) // 4
                else:
                    tokens = [183_000, 184_000, 1_000][min(len(owner.requests) - 1, 2)]
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
        self.provider.write_text('''const originalFetch = globalThis.fetch;
globalThis.fetch = (input: any, init?: any) => String(input) === "https://api.typesafe.ai/v1/systemone"
  ? originalFetch("http://127.0.0.1:PORT/jev", init) : originalFetch(input, init);
export default function(pi: any) {
  const model = (id: string, contextWindow: number) => ({ id, name: id, reasoning: true,
    input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow, maxTokens: 16384 });
  pi.registerProvider("rollover-test", {
    baseUrl: "http://127.0.0.1:PORT/v1", apiKey: "local-test", api: "openai-completions",
    models: [model("large", 1050000), model("pruning", 200000)]
  });
  pi.registerCommand("probe", { description: "trigger a turn without a new user goal", handler: async () => {
    pi.sendMessage({ customType: "probe", content: "continue", display: false }, { triggerTurn: true });
  }});
}
'''.replace("PORT", str(self.server.server_port)))

    def start(self, extensions, cwd, session=None, model="large"):
        cwd.mkdir(parents=True, exist_ok=True)
        cmd = [shutil.which("pi"), "--mode", "rpc", "--no-extensions", "--no-skills",
               "--no-prompt-templates", "--model", f"rollover-test/{model}", "--thinking", "medium",
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
            if proc.poll() is None:
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
        slash = kind == "prompt" and values.get("message", "").startswith("/")
        while True:
            event = self.queue.get(timeout=20)
            if kind == "prompt" and event.get("type") == "agent_settled":
                return
            if event.get("type") == "response" and event.get("command") == kind:
                self.assertTrue(event["success"], event)
                if kind != "prompt" or slash:
                    return event.get("data", {})

    def wait_settled(self):
        while self.queue.get(timeout=20).get("type") != "agent_settled":
            pass

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

    def pruning_fixture(self, name):
        cwd = self.home / name
        cwd.mkdir()
        (cwd / ".git").mkdir()
        outside = self.home / "outside.txt"
        outside.write_text("outside")
        (cwd / "link.txt").symlink_to(outside)
        stamp = int(time.time() * 1000) - 60_000
        now = datetime.now(timezone.utc).isoformat()
        entries = [{"type": "session", "version": 3, "id": str(uuid.uuid4()), "timestamp": now, "cwd": str(cwd)}]
        parent = None

        def add(message):
            nonlocal parent
            entry_id = f"e{len(entries):04d}"
            entries.append({"type": "message", "id": entry_id, "parentId": parent, "timestamp": now, "message": message})
            parent = entry_id
            return entry_id

        def pair(key, tool="read", text=None, path=None, **extra):
            path = path or f"files/{key}.txt"
            if not path.startswith("/") and not path.startswith("../"):
                target = cwd / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(key)
            add({"role": "assistant", "content": [{"type": "thinking", "thinking": "fixture", "thinkingSignature": "opaque"},
                 {"type": "toolCall", "id": key, "name": tool, "arguments": {"path": path}}],
                 "api": "openai-completions", "provider": "rollover-test", "model": "large", "usage": {},
                 "stopReason": "toolUse", "timestamp": stamp})
            return add({"role": "toolResult", "toolCallId": key, "toolName": tool,
                        "content": [{"type": "text", "text": text or (key + "\n") * 1400}],
                        "isError": False, "details": {"fixture": key}, "timestamp": stamp, **extra})

        first_user = add({"role": "user", "content": "Original synthetic task; keep protected evidence.", "timestamp": stamp})
        old_ids = [pair(f"old_{i}", text=(f"OLD_{i} complete body\n" * 2500)) for i in range(12)]
        pair("read_error", text="ERROR protected\n" * 200, isError=True)
        pair("write_receipt", tool="write", text="WRITE protected\n" * 200)
        pair("truncated", text="TRUNCATED protected\n" * 200, details={"truncation": {"truncated": True}})
        pair("outside", text="OUTSIDE protected\n" * 200, path="../outside.txt")
        pair("symlink", text="SYMLINK protected\n" * 200, path="link.txt")
        pair("image", text="IMAGE fallback", content=[{"type": "image", "mimeType": "image/png", "data": "AA=="}])
        add({"role": "assistant", "content": [
            {"type": "toolCall", "id": "batch_done", "name": "read", "arguments": {"path": "files/batch.txt"}},
            {"type": "toolCall", "id": "batch_open", "name": "read", "arguments": {"path": "files/open.txt"}}],
            "api": "openai-completions", "provider": "rollover-test", "model": "large", "usage": {},
            "stopReason": "toolUse", "timestamp": stamp})
        (cwd / "files/batch.txt").write_text("batch")
        add({"role": "toolResult", "toolCallId": "batch_done", "toolName": "read",
             "content": [{"type": "text", "text": "OPEN BATCH protected\n" * 200}], "isError": False,
             "details": {"fixture": "batch"}, "timestamp": stamp})
        recent = [pair(f"recent_{i}", text=(f"RECENT_{i} pinned\n" * 1800)) for i in range(3)]
        path = cwd / "session.jsonl"
        original = "".join(json.dumps(entry) + "\n" for entry in entries)
        path.write_text(original)
        return cwd, path, original, first_user, old_ids, recent

    def run_pruning(self, name, mode="on", response="valid", key=True):
        self.estimate_tokens = True
        self.jev_mode = response
        if not key:
            self.env.pop("TYPESAFEAI_API_KEY", None)
        cwd, session, original, first_user, old_ids, recent = self.pruning_fixture(name)
        self.start([EXTENSIONS / "scoped/no-summary-rollover/index.ts"], cwd, str(session), "pruning")
        control = f"/jev-pruning {mode} personal Cockpit synthetic task" if mode in ("shadow", "compact") else f"/jev-pruning {mode}"
        self.command("prompt", message=control)
        self.command("prompt", message="Continue the original synthetic task.")
        payload = self.requests[-1]
        return cwd, session, original, first_user, old_ids, recent, payload

    def test_cockpit_uses_native_threshold_and_retains_identity(self):
        self.check_rollover([EXTENSIONS / "nixos-rollover/index.ts"], self.home / "personal/ai-cockpit")

    def test_worker_manifest_loads_the_same_policy(self):
        manifest = ROOT / "dotfiles/ai/roles/manifest.json"
        worker = json.loads(manifest.read_text())["profiles"]["lovable-worker"]
        extensions = [manifest.parent / value for value in worker["extensions"] if "/scoped/" in value]
        self.check_rollover(extensions, self.home / "src/lovable-every-1")

    def test_jev_modes_transport_pins_metadata_and_recovery(self):
        for mode, expect_jev, expect_omitted in [("off", False, False), ("shadow", True, False), ("on", True, True)]:
            with self.subTest(mode=mode):
                self.requests.clear(); self.jev_requests.clear()
                cwd, session, original, _, old_ids, _, payload = self.run_pruning(f"mode-{mode}", mode)
                sent = json.dumps(payload)
                self.assertEqual(bool(self.jev_requests), expect_jev)
                self.assertEqual("Jev omitted" in sent, expect_omitted)
                self.assertTrue(session.read_text().startswith(original))
                if expect_jev:
                    self.assertLessEqual(len(self.jev_requests), 4)
                    for headers, body in self.jev_requests:
                        self.assertEqual(headers["authorization"], "Bearer synthetic-test-key")
                        self.assertLessEqual(len(json.dumps(body).encode()), 65_536)
                        if mode == "shadow":
                            self.assertEqual(body["state"]["task"], "personal Cockpit synthetic task")
                            self.assertTrue(all(read["tool"] == "read" for read in body["state"]["history"]))
                            self.assertTrue(all(f"call_{read['id']}" in body["questions"] and
                                                f"result_{read['id']}" in body["questions"]
                                                for read in body["state"]["history"]))
                            self.assertNotIn("OLD_0 complete body", json.dumps(body))
                            self.assertNotIn("Continue the original synthetic task.", json.dumps(body))
                            self.assertNotIn("OUTSIDE protected", json.dumps(body))
                            self.assertTrue(all(Path(read["path"]).is_relative_to(cwd) for read in body["state"]["history"]))
                        else:
                            self.assertTrue(all(len(read["content"][0]["text"].encode()) >= 1024 for read in body["state"]["reads"]))
                if mode == "on":
                    for marker in ["ERROR protected", "WRITE protected", "TRUNCATED protected", "OUTSIDE protected",
                                   "SYMLINK protected", "image/png", "OPEN BATCH protected", "RECENT_0 pinned",
                                   "RECENT_1 pinned", "RECENT_2 pinned"]:
                        self.assertIn(marker, sent)
                    entries = self.command("get_entries")["entries"]
                    passes = [e for e in entries if e.get("customType") == "jev-pruning" and e.get("data", {}).get("kind") == "pass"]
                    self.assertEqual(passes[-1]["data"]["models"], ["jev-test"])
                    original_result = next(e for e in entries if e.get("id") == old_ids[0])
                    self.assertIn("OLD_0 complete body", json.dumps(original_result))
                    self.assertNotIn("OLD_0 complete body", sent)

    def test_compact_shortens_real_pi_request_without_changing_saved_history(self):
        self.requests.clear(); self.jev_requests.clear()
        _, _, _, _, _, _, plain = self.run_pruning("compact-baseline", mode="off")
        before = len(json.dumps(plain).encode())
        self.proc.stdin.close(); self.proc.wait(timeout=10)
        self.requests.clear(); self.jev_requests.clear()
        _, session, original, _, old_ids, _, compacted = self.run_pruning("compact-once", mode="compact")
        after = len(json.dumps(compacted).encode())
        sent = json.dumps(compacted)
        self.assertLess(after, before * 0.8, (before, after))
        self.assertEqual(len(self.jev_requests), 1)
        body = self.jev_requests[0][1]
        self.assertEqual(body["state"]["task"], "personal Cockpit synthetic task")
        self.assertEqual(len(body["questions"]), 2 * len(body["state"]["history"]))
        self.assertNotIn("OLD_0 complete body", json.dumps(body))
        self.assertNotIn("OLD_0 complete body", sent)
        self.assertIn("RECENT_2 pinned", sent)
        self.assertIn("ERROR protected", sent)
        self.assertTrue(session.read_text().startswith(original))
        entries = self.command("get_entries")["entries"]
        saved = next(entry for entry in entries if entry.get("id") == old_ids[0])
        self.assertIn("OLD_0 complete body", json.dumps(saved))

    def test_jev_on_resume_reuses_saved_selection(self):
        cwd, session, _, _, _, _, first = self.run_pruning("resume-on")
        self.assertIn("Jev omitted", json.dumps(first))
        classified = len(self.jev_requests)
        main_requests = len(self.requests)
        self.proc.stdin.close(); self.proc.wait(timeout=10)
        self.start([EXTENSIONS / "scoped/no-summary-rollover/index.ts"], cwd, str(session), "pruning")
        self.command("prompt", message="/probe")
        self.wait_settled()
        self.assertEqual(len(self.jev_requests), classified)
        self.assertEqual(len(self.requests), main_requests + 1)
        self.assertIn("Jev omitted", json.dumps(self.requests[-1]))

    def test_jev_fail_closed_and_cancellation(self):
        for response, key in [("invalid", True), ("partial", True), ("outofrange", True), ("valid", False)]:
            with self.subTest(response=response, key=key):
                self.requests.clear(); self.jev_requests.clear()
                *_, payload = self.run_pruning(f"failure-{response}-{key}", response=response, key=key)
                self.assertNotIn("Jev omitted", json.dumps(payload))
        secrets = self.home / ".config/fish/secrets.fish"
        secrets.parent.mkdir(parents=True)
        secrets.write_text("echo MUST_NOT_ESCAPE\nset -gx TYPESAFEAI_API_KEY fish-synthetic-key\n")
        self.requests.clear(); self.jev_requests.clear()
        *_, fallback = self.run_pruning("fish-fallback", key=False)
        self.assertIn("Jev omitted", json.dumps(fallback))
        self.assertTrue(self.jev_requests)
        self.assertTrue(all(headers["authorization"] == "Bearer fish-synthetic-key"
                            for headers, _ in self.jev_requests))
        self.requests.clear(); self.jev_requests.clear(); self.env["TYPESAFEAI_API_KEY"] = "synthetic-test-key"
        self.jev_delay = 3
        *_, timed_out = self.run_pruning("failure-timeout")
        self.assertNotIn("Jev omitted", json.dumps(timed_out))
        self.proc.stdin.close(); self.proc.wait(timeout=10)
        self.jev_started.clear()
        cwd, session, *_ = self.pruning_fixture("cancel")
        self.start([EXTENSIONS / "scoped/no-summary-rollover/index.ts"], cwd, str(session), "pruning")
        self.command("prompt", message="/jev-pruning on")
        self.proc.stdin.write(json.dumps({"type": "prompt", "message": "Trigger cancellation."}) + "\n")
        self.proc.stdin.flush()
        self.assertTrue(self.jev_started.wait(5))
        self.command("abort")
        time.sleep(.1)
        self.assertFalse(any("Jev omitted" in json.dumps(request) for request in self.requests))

    def test_jev_native_overflow_checkpoints_and_retries(self):
        self.overflow_once = True
        cwd, session, _, _, _, _, _ = self.run_pruning("overflow")
        self.assertTrue(self.overflow_sent)
        self.assertEqual(len(self.requests), 2, "overflow must retry the main provider exactly once")
        self.assertTrue(self.jev_requests)
        self.assertLessEqual(len(self.jev_requests), 4)
        for request in self.requests:
            sent = json.dumps(request)
            self.assertNotIn("OLD_0 complete body", sent)
        entries = [json.loads(line) for line in session.read_text().splitlines()]
        checkpoints = [entry for entry in entries if entry.get("type") == "compaction"]
        passes = [entry for entry in entries if entry.get("customType") == "jev-pruning"
                  and entry.get("data", {}).get("kind") == "pass"]
        self.assertEqual(len(checkpoints), 1)
        self.assertEqual(len(passes), 1, "overflow retry must reuse the saved classification")
        self.assertEqual(checkpoints[0]["details"]["strategy"], "deterministic-auto-v3")
        self.assertIn("Recovery checkpoint", json.dumps(self.requests[-1]))

    def test_jev_saved_selection_lifecycle_and_native_savings(self):
        self.requests.clear(); self.jev_requests.clear()
        cwd, session, original, first_user, _, _, first_payload = self.run_pruning("lifecycle")
        filtered_size = len(json.dumps(first_payload["messages"]).encode())
        self.assertFalse(any(json.loads(line).get("type") == "compaction" for line in session.read_text().splitlines()))
        request_count = len(self.jev_requests)
        self.command("prompt", message="A new task must reassess saved selections.")
        self.assertGreater(len(self.jev_requests), request_count)
        reassessed_count = len(self.jev_requests)
        self.command("prompt", message="/jev-pruning off")
        self.command("prompt", message="Off restores original active history.")
        self.assertIn("OLD_0 complete body", json.dumps(self.requests[-1]))
        self.proc.stdin.close(); self.proc.wait(timeout=10)
        self.start([EXTENSIONS / "scoped/no-summary-rollover/index.ts"], cwd, str(session), "pruning")
        before_resume_jev = len(self.jev_requests)
        self.command("prompt", message="Resume after restart remains off.")
        self.assertEqual(len(self.jev_requests), before_resume_jev)
        self.assertIn("Recovery checkpoint", json.dumps(self.requests[-1]))
        self.command("fork", entryId=first_user)
        self.command("prompt", message="Forked task starts from old branch point.")
        self.assertEqual(len(self.jev_requests), reassessed_count, "fork must not revive an off branch selection")
        self.assertNotIn("OLD_0 complete body", json.dumps(self.requests[-1]))
        self.assertTrue(session.read_text().startswith(original))
        self.proc.stdin.close(); self.proc.wait(timeout=10)

        self.requests.clear(); self.jev_requests.clear()
        _, baseline_session, _, _, _, _, baseline = self.run_pruning("baseline", mode="off")
        baseline_size = len(json.dumps(baseline["messages"]).encode())
        self.command("prompt", message="Second baseline turn triggers native rollover.")
        baseline_compactions = sum(json.loads(line).get("type") == "compaction" for line in baseline_session.read_text().splitlines())
        self.assertGreater(baseline_compactions, 0)
        self.assertGreater(baseline_size / 4, 183_616)
        self.assertLess(filtered_size / 4, 183_616)
        self.assertLess(filtered_size, baseline_size * .8)
        self.proc.stdin.close(); self.proc.wait(timeout=10)

        self.requests.clear(); self.jev_requests.clear(); self.jev_delay = 0
        self.forced_tokens = 190_000
        _, checkpoint_session, _, _, _, _, _ = self.run_pruning("checkpoint")
        self.command("prompt", message="Force the native checkpoint while selections are active.")
        checkpoints = [json.loads(line) for line in checkpoint_session.read_text().splitlines()
                       if json.loads(line).get("type") == "compaction"]
        self.assertTrue(checkpoints)
        self.assertNotIn("OLD_0 complete body", checkpoints[-1]["summary"], "checkpoint resurrected a selected read")


if __name__ == "__main__":
    unittest.main()
