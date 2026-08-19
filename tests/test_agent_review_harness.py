#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "dotfiles/niri/.config/niri/scripts/agent_review_harness.py"
spec = importlib.util.spec_from_file_location("agent_review_harness", MODULE)
harness = importlib.util.module_from_spec(spec)
assert spec.loader
sys.modules[spec.name] = harness
spec.loader.exec_module(harness)


class HarnessTests(unittest.TestCase):
    def context(self, home: Path, worktree: Path | None = None):
        worktree = worktree or home / "review"
        worktree.mkdir(parents=True, exist_ok=True)
        return harness.ManualHarness(
            home=home,
            pr=83188,
            expected_sha="9" * 40,
            project_id="11111111-2222-4333-8444-555555555555",
            worktree=worktree,
            ports=harness.HarnessPorts(3000, 9341, 51320, 51302, 8020, 51300, 51302),
            vm_host="review-vm.example",
            vm_user="reviewer",
            state_home=home / ".local/state",
        )

    def test_deterministic_tools_use_valid_cache_and_prepend_path(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cache = home / "cache"
            tools = home / "store/bin"
            tools.mkdir(parents=True)
            for name in ("git-lfs", "wt"):
                executable = tools / name
                executable.write_text("#!/bin/sh\nexit 0\n")
                executable.chmod(0o755)
                (cache / name).parent.mkdir(parents=True, exist_ok=True)
                (cache / name).write_text(str(executable))
            old_path = os.environ.get("PATH", "")
            try:
                resolved = harness.deterministic_path(home, cache)
                self.assertEqual(resolved["git-lfs"], (tools / "git-lfs").resolve())
                self.assertEqual(os.environ["PATH"].split(os.pathsep)[0], str(tools))
            finally:
                os.environ["PATH"] = old_path

    def test_adopts_clean_exact_head_worktree_regardless_of_slug(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            review = root / "unexpected-existing-name"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("a")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-qb", "review/pr-42", str(review), sha], check=True)
            original = harness.run
            calls = []
            def fake_run(args, **kwargs):
                calls.append(args)
                if args[:4] == ["git", "-C", str(review), "lfs"]:
                    return subprocess.CompletedProcess(args, 0, "", "")
                return original(args, **kwargs)
            with mock.patch.object(harness, "run", side_effect=fake_run):
                adopted = harness.adopt_or_create_worktree(repo, 42, sha, root / "new-slug")
            self.assertEqual(adopted, review)
            self.assertFalse(any("reset" in args for args in calls))

    def test_clean_stale_worktree_updates_to_exact_head(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo, review = root / "repo", root / "review"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("base")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            stale_sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            (repo / "a").write_text("head")
            subprocess.run(["git", "-C", str(repo), "commit", "-qam", "head"], check=True)
            expected_sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-qb", "review/pr-8", str(review), stale_sha], check=True)
            original = harness.run
            def fake_run(args, **kwargs):
                if args[:4] == ["git", "-C", str(review), "lfs"]:
                    return subprocess.CompletedProcess(args, 0, "", "")
                return original(args, **kwargs)
            with mock.patch.object(harness, "run", side_effect=fake_run):
                adopted = harness.adopt_or_create_worktree(repo, 8, expected_sha, root / "other")
            self.assertEqual(adopted, review)
            self.assertEqual(harness.git(["rev-parse", "HEAD"], review), expected_sha)
            self.assertEqual((review / "a").read_text(), "head")

    def test_dirty_adopted_worktree_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo, review = root / "repo", root / "review"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("a")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-qb", "review/pr-7", str(review), sha], check=True)
            (review / "dirty").write_text("x")
            with self.assertRaisesRegex(RuntimeError, "dirty"):
                harness.adopt_or_create_worktree(repo, 7, sha, root / "other")

    def test_locally_ahead_worktree_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo, review = root / "repo", root / "review"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("base")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            expected_sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            (repo / "a").write_text("local")
            subprocess.run(["git", "-C", str(repo), "commit", "-qam", "local"], check=True)
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-qb", "review/pr-9", str(review), "HEAD"], check=True)
            with self.assertRaisesRegex(RuntimeError, "not behind"):
                harness.adopt_or_create_worktree(repo, 9, expected_sha, root / "other")

    def test_remote_clean_stale_worktree_updates_but_dirty_or_ahead_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).remote_setup_script()
            dirty = text.index("remote review worktree is dirty")
            ancestry = text.index("merge-base --is-ancestor")
            reset = text.index('reset --hard "9999999999999999999999999999999999999999"')
            verified = text.index("remote review worktree SHA mismatch after update")
            self.assertEqual([dirty, ancestry, reset, verified], sorted([dirty, ancestry, reset, verified]))
            self.assertIn("remote review worktree is not behind PR head", text)
            self.assertNotIn("reset --hard HEAD", text)

    def test_context_artifacts_encode_proven_environment_and_owned_services(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            manual = self.context(home)
            context = manual.write()
            remote = manual.remote_setup_script()
            self.assertIn("npm_config_enable_global_virtual_store=false", remote)
            self.assertIn("pnpm --config.enableGlobalVirtualStore=false install --force", remote)
            self.assertIn("PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE=false", remote)
            self.assertIn("patchelf", remote)
            self.assertIn("GO_SCHEDULER_BASE_URL=https://sandbox-scheduler.gcp-euw4.d.l5e.io", remote)
            self.assertIn("GO_SCHEDULER_GRPC_ADDR=https://sandbox-scheduler.gcp-euw4.d.l5e.io", remote)
            self.assertIn("devenv wt --no-tui --base-port 51300", remote)
            connectivity = (manual.root / context.units["connectivity"]).read_text()
            for forward in ("51320:127.0.0.1:51300", "51302:127.0.0.1:51302", "8020:127.0.0.1:51302"):
                self.assertIn(forward, connectivity)
            self.assertIn("Restart=always", connectivity)
            self.assertNotIn("WantedBy", connectivity)
            browser = (manual.root / context.units["browser"]).read_text()
            self.assertIn("--user-data-dir=", browser)
            self.assertIn("--remote-debugging-port=9341", browser)
            self.assertIn("--disable-extensions", browser)
            self.assertIn("about:blank", browser)
            proxy = (manual.root / "keyless-proxy.mjs").read_text()
            self.assertIn("matches.length!==1", proxy)
            metadata = json.loads((manual.root / "context.json").read_text())
            self.assertEqual(metadata["context_id"], "pr-83188")
            self.assertFalse(metadata["enabled_at_boot"])
            self.assertEqual(metadata["remote_units"]["vm_slice"], "agent-review-pr-83188-vm.service")
            certification = (manual.root / "browser-readiness.mjs").read_text()
            for proof in ("CONNECTION_HELLO", "scriptVersion", "vite-hmr", "DS_SPECIMEN_PROPS", "live iframe identity changed"):
                self.assertIn(proof, certification)
            self.assertIn("sandbox-start one-shot marker already exists", certification)

    def test_sandbox_start_collector_blocks_second_post_before_execution(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            request_gate = text.index('isSandboxStart=request.method==="POST"')
            duplicate_gate = text.index("if(startRequest){blockedDuplicateStarts++", request_gate)
            duplicate_block = text.index('Fetch.failRequest",{requestId:event.params.requestId', duplicate_gate)
            first_record = text.index("startRequest={fetchRequestId:", duplicate_block)
            first_continue = text.index('Fetch.continueRequest",{requestId:event.params.requestId}', first_record)
            duplicate_failure = text.index("blocked ${blockedDuplicateStarts} duplicate sandbox-start attempt(s)", first_continue)
            self.assertEqual(
                [request_gate, duplicate_gate, duplicate_block, first_record, first_continue, duplicate_failure],
                sorted([request_gate, duplicate_gate, duplicate_block, first_record, first_continue, duplicate_failure]),
            )
            self.assertEqual(text.count("startRequest={fetchRequestId:"), 1)
            self.assertEqual(text.count("blockedDuplicateStarts++"), 1)

    def test_sandbox_start_collector_records_one_request_response_pair(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            request = text.index("startRequest={fetchRequestId:")
            response = text.index("startResponse={status:response.status", request)
            missing_response = text.index("sandbox-start request completed without an observed response", response)
            certification = text.index("sandboxStart:startRequest?{request:startRequest,response:startResponse}", missing_response)
            self.assertEqual([request, response, missing_response, certification], sorted([request, response, missing_response, certification]))
            recorded_request = text[request:text.index("};await parent.send", request)]
            self.assertNotIn("headers", recorded_request)
            self.assertNotIn("Authorization", recorded_request)

    def test_specimen_reset_is_required_before_success_certification(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            finally_at = text.index("}finally{")
            reset_at = text.index('payload:{props:{}}', finally_at)
            restored_at = text.index('restored:digest(restored)', reset_at)
            write_at = text.index("fs.writeFileSync(certification", restored_at)
            self.assertLess(finally_at, reset_at)
            self.assertLess(reset_at, restored_at)
            self.assertLess(restored_at, write_at)
            self.assertIn('if(restored!==before)throw Error("DS specimen reset did not restore', text)
            self.assertIn("restoredTargetIds:{live:liveId,specimen:specimenId}", text)

    def test_specimen_reset_also_runs_after_mutation_failure(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            mutation_at = text.index("mutationSent=true")
            catch_at = text.index("}catch(error){failure=error", mutation_at)
            finally_at = text.index("}finally{", catch_at)
            reset_guard_at = text.index("if(mutationSent&&parent&&specimen", finally_at)
            failure_at = text.index("if(failure)throw failure", reset_guard_at)
            self.assertLess(mutation_at, catch_at)
            self.assertLess(catch_at, finally_at)
            self.assertLess(finally_at, reset_guard_at)
            self.assertLess(reset_guard_at, failure_at)
            self.assertIn("certification failed and specimen reset failed", text)

    def test_incomplete_canvas_runtime_fingerprint_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            self.assertIn('runtimeVersion!=="2026-08-17.2"', text)
            self.assertIn("d095fa605d961269d9e25b0f456da72cade838b64561af75f5c52c148e6a2430", text)
            self.assertIn("49fc9bddb4ff4d5cd63ba9af87f43c207e3659479360f23a3721f44bb85ae85f", text)
            self.assertIn("Object.values(runtimeCapabilities).some(value=>!value)", text)
            self.assertIn("authoritative fingerprint or handler completeness is invalid", text)

    def test_phase_one_readiness_is_ordered_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            manual = self.context(Path(td))
            text = manual.render_readiness()
            checks = [
                "worktree SHA", "served SHA mismatch", "systemctl", "await hmr", "/health",
                "Authorization header required",
            ]
            positions = [text.index(check) for check in checks]
            self.assertEqual(positions, sorted(positions))
            self.assertIn("Date.now()+60000", text)

    def test_browser_profile_requires_stopped_authenticated_seed(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            seed = home / "seed"
            seed.mkdir()
            (seed / "SingletonLock").write_text("active")
            with mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(home / ".local/state")}):
                manual = harness.ManualHarness(
                    home=home, pr=2, expected_sha="2" * 40, project_id="project",
                    worktree=home / "review", ports=harness.HarnessPorts(3000, 9341, 51320, 51302, 8020, 51300, 51302),
                    vm_host="host", vm_user="user", browser_profile_seed=seed,
                )
                manual.write()
                with self.assertRaisesRegex(RuntimeError, "appears active"):
                    manual.prepare_browser_profile()
                (seed / "SingletonLock").unlink()
                (seed / "Default").mkdir()
                (seed / "Default/Cookies").write_text("encrypted-auth-state")
                manual.prepare_browser_profile()
                self.assertEqual((manual.root / "browser-profile/Default/Cookies").read_text(), "encrypted-auth-state")

    def test_teardown_removes_only_owned_context(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            state = home / ".local/state"
            with mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(state)}):
                manual = self.context(home)
                context = manual.write()
                unit_dir = home / ".config/systemd/user"
                unit_dir.mkdir(parents=True)
                for unit in context.units.values():
                    (unit_dir / unit).symlink_to(manual.root / unit)
                unrelated = state / "agent-review/pr-999/context.json"
                unrelated.parent.mkdir(parents=True)
                unrelated.write_text("keep")
                seed = home / ".config/chromium-agent-review-seed"
                helium = home / ".config/helium"
                seed.mkdir(parents=True)
                helium.mkdir(parents=True)
                (seed / "Cookies").write_text("seed")
                (helium / "Cookies").write_text("normal-browser")
                (manual.root / "browser-profile").mkdir()
                (manual.root / "browser-profile/Cookies").write_text("clone")
                calls = []
                with mock.patch.object(harness, "run", side_effect=lambda args, **kwargs: calls.append(args) or subprocess.CompletedProcess(args, 0, "", "")):
                    harness.teardown_context(home, "pr-83188")
                self.assertFalse(manual.root.exists())
                self.assertEqual(unrelated.read_text(), "keep")
                self.assertEqual((seed / "Cookies").read_text(), "seed")
                self.assertEqual((helium / "Cookies").read_text(), "normal-browser")
                self.assertTrue(any(args[:3] == ["systemctl", "--user", "stop"] for args in calls))
                self.assertTrue(any(args[0] == "/run/current-system/sw/bin/ssh" for args in calls))
                self.assertFalse(any("helium" in str(part).lower() for args in calls for part in args))

    def test_teardown_rejects_unknown_or_forged_context(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            with mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(home / ".local/state")}):
                with self.assertRaisesRegex(RuntimeError, "context id"):
                    harness.teardown_context(home, "../pr-1")
                root = home / ".local/state/agent-review/pr-1"
                root.mkdir(parents=True)
                (root / "context.json").write_text(json.dumps({
                    "context_id": "pr-1", "units": {"bad": "ssh.service"}, "remote_units": {},
                }))
                with self.assertRaisesRegex(RuntimeError, "unsafe"):
                    harness.teardown_context(home, "pr-1")


if __name__ == "__main__":
    unittest.main()
