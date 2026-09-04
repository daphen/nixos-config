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
    def context(self, home: Path, worktree: Path | None = None, **kwargs):
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
            **kwargs,
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

    def test_clean_detached_review_worktree_reattaches_and_updates(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo, review = root / "repo", root / "review"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("base")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            stale_sha = harness.git(["rev-parse", "HEAD"], repo)
            subprocess.run(["git", "-C", str(repo), "branch", "review/pr-10", stale_sha], check=True)
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "--detach", str(review), stale_sha], check=True)
            (repo / "a").write_text("head")
            subprocess.run(["git", "-C", str(repo), "commit", "-qam", "head"], check=True)
            expected_sha = harness.git(["rev-parse", "HEAD"], repo)
            original = harness.run
            def fake_run(args, **kwargs):
                if args[:4] == ["git", "-C", str(review), "lfs"]:
                    return subprocess.CompletedProcess(args, 0, "", "")
                return original(args, **kwargs)
            with mock.patch.object(harness, "run", side_effect=fake_run):
                adopted = harness.adopt_or_create_worktree(repo, 10, expected_sha, review)
            self.assertEqual(adopted, review)
            self.assertEqual(harness.git(["rev-parse", "--abbrev-ref", "HEAD"], review), "review/pr-10")
            self.assertEqual(harness.git(["rev-parse", "HEAD"], review), expected_sha)

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

    def test_dirty_detached_review_worktree_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo, review = root / "repo", root / "review"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("a")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            sha = harness.git(["rev-parse", "HEAD"], repo)
            subprocess.run(["git", "-C", str(repo), "branch", "review/pr-11", sha], check=True)
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "--detach", str(review), sha], check=True)
            (review / "dirty").write_text("x")
            with self.assertRaisesRegex(RuntimeError, "dirty"):
                harness.adopt_or_create_worktree(repo, 11, sha, review)

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

    def test_locally_ahead_detached_review_worktree_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo, review = root / "repo", root / "review"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "a").write_text("base")
            subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            expected_sha = harness.git(["rev-parse", "HEAD"], repo)
            (repo / "a").write_text("local")
            subprocess.run(["git", "-C", str(repo), "commit", "-qam", "local"], check=True)
            local_sha = harness.git(["rev-parse", "HEAD"], repo)
            subprocess.run(["git", "-C", str(repo), "branch", "review/pr-12", local_sha], check=True)
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "--detach", str(review), local_sha], check=True)
            with self.assertRaisesRegex(RuntimeError, "not behind"):
                harness.adopt_or_create_worktree(repo, 12, expected_sha, review)

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
            self.assertIn("--window-size=1920,1080", browser)
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
            self.assertIn("sandbox-start POST was already issued", certification)

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

    def test_existing_sandbox_recovery_fulfills_attach_from_allowlisted_get(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            gate = text.index('if(isSandboxStart&&!allowStart)')
            recovery_block = text[gate:text.index('}else if(isSandboxStart){', gate)]
            discovery = recovery_block.index('/sandbox/url`,{headers:{Authorization:authorization}')
            allowlist = recovery_block.index('if(isProjectHost(host))', discovery)
            fulfill = recovery_block.index('Fetch.fulfillRequest', allowlist)
            response = recovery_block.index('body:Buffer.from(JSON.stringify(discovered))', fulfill)
            self.assertEqual([discovery, allowlist, fulfill, response], sorted([discovery, allowlist, fulfill, response]))
            self.assertNotIn('prior?.state', recovery_block)
            self.assertNotIn('Fetch.continueRequest', recovery_block)
            self.assertNotIn('method:"POST"', recovery_block)
            self.assertNotIn('Fetch.failRequest', recovery_block[allowlist:response])
            self.assertIn('host=>host===`${projectId}.lovableproject-dev.com`||host===`id-preview--${projectId}.gpt-eng.com`', text)

    def test_cdp_evaluation_surfaces_the_remote_exception_description(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            self.assertIn('result.exceptionDetails.exception?.description??result.exceptionDetails.text', text)

    def test_malformed_or_empty_cdp_target_urls_are_ignored_and_page_uses_runtime_location(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            self.assertIn('const targetUrl=target=>{try{return new URL(target.url)}catch{return null;}}', text)
            self.assertIn('readyPageUrl=new URL(await parent.evaluate("location.href"))', text)
            self.assertNotIn('readyPage?new URL(readyPage.url)', text)
            self.assertNotIn('new URL(target.url).pathname', text)

    def test_live_sandbox_targets_use_the_same_exact_host_allowlist(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            selector = text[text.index('const isProjectHost='):text.index('let list=await targets()')]
            self.assertIn('host===`${projectId}.lovableproject-dev.com`', selector)
            self.assertIn('host===`id-preview--${projectId}.gpt-eng.com`', selector)
            self.assertIn('isProjectHost(url.hostname)', selector)
            self.assertNotIn('.includes(', selector)
            specimen = text[text.index('const specimenTarget='):text.index('if(!specimenTarget)')]
            self.assertIn('pathname.startsWith("/__component/preview/")', specimen)
            self.assertIn('isProjectHost(url.hostname)', specimen)

    def test_consumed_start_rejects_any_new_start_approval_even_with_live_iframe(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td), allow_sandbox_start=True).render_browser_readiness()
            self.assertIn('if(allowStart&&startState.requestCount>0)throw Error', text)
            self.assertNotIn('if(!live&&allowStart&&startState.requestCount>0)', text)

    def test_consumed_no_start_attach_replaces_only_an_unresponsive_page_target(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td), allow_sandbox_start=False).render_browser_readiness()
            configure = text.index('const configureParent=async target=>')
            timeout_gate = text.index('const unused=startState.requestCount===0&&startState.status==="unused",consumedAttach=startState.requestCount===1&&startState.status==="succeeded"&&!allowStart', configure)
            create = text.index('Target.createTarget', timeout_gate)
            close_old = text.index('Target.closeTarget",{targetId:page.id}', create)
            configure_replacement = text.index('parent=await configureParent(page)', close_old)
            navigation = text.index('await navigate()', configure_replacement)
            self.assertEqual([configure, timeout_gate, create, close_old, configure_replacement, navigation], sorted([configure, timeout_gate, create, close_old, configure_replacement, navigation]))
            self.assertIn('const unused=startState.requestCount===0', text[configure:create])
            self.assertIn('targetRecovery={reason:error.message,replacedTargetId:replacement.targetId}', text)

    def test_browser_certification_always_performs_fresh_intercepted_navigation(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            interception = text.index('Fetch.enable')
            navigation = text.index('Page.navigate', interception)
            self.assertLess(interception, navigation)
            self.assertIn('agent_review_certification=${Date.now()}', text[navigation:])
            self.assertNotIn('Page.reload', text)

    def test_browser_readiness_recovers_cold_vite_502_once_before_start(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            failure_capture = text.index('response.status>=500&&parsed.origin===browserOrigin')
            recovery_gate = text.index('!startRequest&&!recoveryNavigated&&failedModuleUrls.size', failure_capture)
            health_proof = text.index('const response=await fetch(url', recovery_gate)
            retry = text.index('recoveryNavigated=true;apiStatus=null;apiAuthorization=null;await navigate()', health_proof)
            mutation = text.index('DS_SPECIMEN_PROPS', retry)
            self.assertEqual([failure_capture, recovery_gate, health_proof, retry, mutation], sorted([failure_capture, recovery_gate, health_proof, retry, mutation]))
            self.assertIn('navigationRecovery:{attempts:navigationAttempts,recovered:recoveryNavigated}', text)
            self.assertIn('Date.now()+180000', text)

    def test_approved_start_requires_authenticated_project_probe_before_post(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td), allow_sandbox_start=True).render_browser_readiness()
            approved = text.index('}else if(isSandboxStart){')
            authorization = text.index('const authorization=request.headers?.Authorization', approved)
            preflight = text.index('const preflight=await fetch(`http://127.0.0.1:51302/projects/${projectId}/sandbox/url`', authorization)
            success = text.index('if(!preflight.ok||!isProjectHost(preflightHost))', preflight)
            allowlist = text.index('isProjectHost(preflightHost)', success)
            continue_post = text.index('Fetch.continueRequest', allowlist)
            account = text.index('startState.requestCount++', continue_post)
            self.assertEqual([approved, authorization, preflight, success, allowlist, continue_post, account], sorted([approved, authorization, preflight, success, allowlist, continue_post, account]))

    def test_authenticated_project_success_accepts_only_gets_in_exact_project_namespace(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            observer = text.index('if(requestMethods.get(event.params.requestId)==="GET"')
            exact = text.index('parsed.pathname===`/projects/${projectId}`', observer)
            descendants = text.index('parsed.pathname.startsWith(`/projects/${projectId}/`)', exact)
            success = text.index('response.status>=200&&response.status<300', descendants)
            self.assertEqual([observer, exact, descendants, success], sorted([observer, exact, descendants, success]))
            self.assertNotIn('requestMethods.get(event.params.requestId)==="POST"&&(parsed.pathname', text)

    def test_authenticated_project_observer_joins_extra_info_in_either_order(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            observer = text.index('Network.requestWillBeSentExtraInfo')
            auth = text.index('requestAuthorizations.set(event.params.requestId,authorization)', observer)
            prior_status = text.index('projectStatuses.get(event.params.requestId)', auth)
            response = text.index('Network.responseReceived', prior_status)
            stored_status = text.index('projectStatuses.set(event.params.requestId,response.status)', response)
            self.assertEqual([observer, auth, prior_status, response, stored_status], sorted([observer, auth, prior_status, response, stored_status]))

    def test_sandbox_start_collector_records_one_request_response_pair(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            request = text.index("startRequest={fetchRequestId:")
            response = text.index("startResponse={status:response.status", request)
            missing_response = text.index("sandbox-start request completed without an observed response", response)
            certification = text.index("sandboxStart:{requestCount:startState.requestCount,status:startState.status", missing_response)
            self.assertEqual([request, response, missing_response, certification], sorted([request, response, missing_response, certification]))
            recorded_request = text[request:text.index('};await parent.send("Fetch.continueRequest"', request)]
            self.assertNotIn("headers", recorded_request)
            self.assertNotIn("Authorization", recorded_request)

    def test_canonical_button_controls_require_desktop_tldraw_breakpoint(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            selection_at = text.index("shape:component-anchor-Button")
            breakpoint_at = text.index("typedControls.breakpoint>=4", selection_at)
            portal_at = text.index("canonical Button typed-controls portal missing", breakpoint_at)
            certification_at = text.index("typedControls:{selection:canonicalSelection", portal_at)
            self.assertEqual([selection_at, breakpoint_at, portal_at, certification_at], sorted([selection_at, breakpoint_at, portal_at, certification_at]))
            for control in ("Specimen", "Reset", "variant", "primary", "size", "md"):
                self.assertIn(control, text)
            self.assertIn("typedControls?.viewport.width!==1920", text)

    def test_fixture_snapshot_requires_preview_and_tldraw_until_deadline(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            loop = text.index('while(Date.now()<deadline&&!fixtureSnapshot)')
            preview = text.index("document.querySelector('#preview-panel')", loop)
            editor = text.index("if(!editor)throw Error('tldraw editor missing')", preview)
            timeout = text.index('if(!fixtureSnapshot)throw fixtureError', editor)
            self.assertEqual([loop, preview, editor, timeout], sorted([loop, preview, editor, timeout]))

    def test_canonical_button_selection_retries_until_ready_or_deadline(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            loop_at = text.index("while(Date.now()<deadline&&!canonicalSelection)")
            shape_at = text.index("shape:component-anchor-Button", loop_at)
            sleep_at = text.index("await sleep(100)", shape_at)
            timeout_at = text.index("canonical Button selection timed out", sleep_at)
            typed_controls_at = text.index("while(Date.now()<deadline){typedControls", timeout_at)
            self.assertEqual(
                [loop_at, shape_at, sleep_at, timeout_at, typed_controls_at],
                sorted([loop_at, shape_at, sleep_at, timeout_at, typed_controls_at]),
            )

    def test_specimen_reset_is_required_before_success_certification(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            finally_at = text.index("}finally{")
            reset_at = text.index('payload:{props:${JSON.stringify(fixtureSnapshot.specimenProps)}}', finally_at)
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

    def test_cleanup_state_is_outer_scoped_for_finally(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            outer = text.index("branchRuntimeUrl=null,apiAuthorization=null,")
            try_at = text.index("try{", outer)
            finally_at = text.index("}finally{", try_at)
            cleanup_use = text.index("JSON.stringify(apiAuthorization)", finally_at)
            self.assertLess(outer, try_at)
            self.assertLess(try_at, finally_at)
            self.assertLess(finally_at, cleanup_use)
            self.assertNotIn("let hydrated=false,apiStatus=null,apiAuthorization=null", text)

    def test_specimen_cleanup_restores_snapshotted_original_props(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            snapshot = text.index("specimenProps:structuredClone(canonical?.props?.specimenProps??{})")
            mutation = text.index('payload:{props:{variant:"destructive"', snapshot)
            finally_at = text.index("}finally{", mutation)
            restore = text.index("payload:{props:${JSON.stringify(fixtureSnapshot.specimenProps)}}", finally_at)
            self.assertEqual([snapshot, mutation, finally_at, restore], sorted([snapshot, mutation, finally_at, restore]))
            self.assertNotIn("payload:{props:{}}", text[finally_at:])

    def test_incomplete_canvas_runtime_fingerprint_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            self.assertIn('runtimeVersion!=="2026-08-17.2"', text)
            self.assertIn("d095fa605d961269d9e25b0f456da72cade838b64561af75f5c52c148e6a2430", text)
            self.assertIn("49fc9bddb4ff4d5cd63ba9af87f43c207e3659479360f23a3721f44bb85ae85f", text)
            self.assertIn("Object.values(runtimeCapabilities).some(value=>!value)", text)
            self.assertIn("authoritative fingerprint or handler completeness is invalid", text)

    def test_remote_setup_fast_paths_exact_ready_context_then_stops_only_its_holder(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).remote_setup_script()
            ready = text.index('bash "$state/readiness.sh" "9999999999999999999999999999999999999999"')
            exit_ready = text.index("exit 0", ready)
            stop_owned = text.index('systemctl --user stop "$unit"', exit_ready)
            install = text.index("pnpm --config.enableGlobalVirtualStore=false install --force", stop_owned)
            patch = text.index('"$patchelf" --set-interpreter', install)
            self.assertEqual([ready, exit_ready, stop_owned, install, patch], sorted([ready, exit_ready, stop_owned, install, patch]))
            self.assertNotIn("pkill", text)
            self.assertNotIn("killall", text)

    def test_sandbox_start_accounting_is_separate_and_consumed_after_post_issue(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            self.assertIn('startStateFile=`${root}/sandbox-start-state.json`', text)
            self.assertNotIn("priorCertification?.sandboxStart", text)
            request = text.index("startRequest={fetchRequestId:")
            continued = text.index('await parent.send("Fetch.continueRequest"', request)
            consumed = text.index("startState.requestCount++", continued)
            issued = text.index('persistStartState("issued"', consumed)
            self.assertEqual([request, continued, consumed, issued], sorted([request, continued, consumed, issued]))
            self.assertNotIn('persistStartState("issuing"', text)
            self.assertIn('sandboxStart:{requestCount:startState.requestCount,status:startState.status', text)

    def test_navigation_timeout_requires_later_exact_app_and_live_iframe_proof(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            timeout = text.index('if(error.message!=="Page.navigate timed out")throw error')
            exact_page = text.index('readyPageUrl.pathname!==`/projects/${projectId}`', timeout)
            live_proof = text.index('if(navigationTimedOut&&!live)throw Error', exact_page)
            self.assertLess(timeout, exact_page)
            self.assertLess(exact_page, live_proof)

    def test_acceptance_provenance_is_complete_and_rejects_mixed_runtime_before_mutation(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            mixed = text.index("mixed production CDN runtime with exact-branch parent")
            snapshot = text.index("fixtureSnapshot=await parent.evaluate", mixed)
            mutation = text.index('type:"DS_SPECIMEN_PROPS"', snapshot)
            self.assertLess(mixed, snapshot)
            self.assertLess(snapshot, mutation)
            for proof in ("servedMonorepoSha", "runtimeSource:{url:", "liveSandboxUrl", "iframeVite101", "connectionHello", "sameDocumentId"):
                self.assertIn(proof, text)
            self.assertIn('transport:"window.postMessage"', text)
            self.assertIn("DS specimen mutation crossed document identity", text)

    def test_exact_branch_runtime_contract_is_context_owned_https_and_browser_local(self):
        with tempfile.TemporaryDirectory() as td:
            manual = self.context(Path(td), runtime_contract="exact-branch")
            remote = manual.remote_setup_script()
            browser = manual.render_browser_readiness()
            units = manual.render_units()
            self.assertIn("pnpm --dir script_tag build", remote)
            self.assertIn("script_tag/dist/lovable.js", remote)
            self.assertIn("runtime_https", manual.units)
            self.assertIn("runtime-https.mjs", units[manual.units["runtime_https"]])
            self.assertIn("--ignore-certificate-errors", units[manual.units["browser"]])
            self.assertIn('const selector="https://cdn.gpteng.co/lovable.js"', browser)
            self.assertIn("Fetch.fulfillRequest", browser)
            self.assertIn("runtimeOverride.url", browser)
            self.assertIn("fetched exact runtime content digest/fingerprint mismatch", browser)
            self.assertIn("iframe-reported runtime version does not match exact runtime contract", browser)
            manual.write()
            self.assertIn("access-control-allow-origin", (manual.root / "runtime-https.mjs").read_text())
            self.assertNotIn("localStorage", browser)

    def test_runtime_contract_rejects_missing_or_wrong_exact_runtime_before_mutation(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError, "runtime_contract"):
                self.context(Path(td), runtime_contract="ticket-special")
            text = self.context(Path(td), runtime_contract="exact-branch").render_browser_readiness()
            missing = text.index("exact-branch runtime contract URL/content digest/fingerprint/script version is missing or invalid")
            wrong = text.index("fetched exact runtime content digest/fingerprint mismatch")
            mutation = text.index('type:"DS_SPECIMEN_PROPS"', wrong)
            self.assertLess(missing, mutation)
            self.assertLess(wrong, mutation)
            self.assertIn("production runtime contract must not load an override artifact", text)

    def test_correct_exact_runtime_contract_requires_url_digest_fingerprint_and_iframe_version(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td), runtime_contract="exact-branch").render_browser_readiness()
            for proof in ("runtimeOverride.url", "runtimeOverride.contentDigest", "runtimeOverride.fingerprint", "runtimeOverride.scriptVersion", "hello.message.payload.scriptVersion!==runtimeOverride.scriptVersion"):
                self.assertIn(proof, text)
            launcher = (ROOT / "dotfiles/niri/.config/niri/scripts/agent-review").read_text()
            self.assertIn("--runtime-contract", launcher)
            self.assertIn("requires explicit --runtime-contract production|exact-branch", launcher)
            self.assertNotIn("every-2739", launcher.lower())

    def test_cleanup_snapshots_fixture_and_deletes_only_attempt_created_candidates(self):
        with tempfile.TemporaryDirectory() as td:
            text = self.context(Path(td)).render_browser_readiness()
            snapshot = text.index("candidateIds:candidates.map")
            selection = text.index("editor.select(shape.id)", snapshot)
            finally_at = text.index("}finally{", selection)
            difference = text.index("!before.candidateIds.includes(shape.id)", finally_at)
            deletion = text.index("editor.deleteShapes(createdCandidates", difference)
            restore_page = text.index("editor.setCurrentPage(before.pageId)", deletion)
            restore_selection = text.index("editor.select(...before.selectedShapeIds)", restore_page)
            self.assertEqual([snapshot, selection, finally_at, difference, deletion, restore_page, restore_selection], sorted([snapshot, selection, finally_at, difference, deletion, restore_page, restore_selection]))
            self.assertIn("candidateFiles:", text)
            self.assertIn("preservedCandidateFiles:before.candidateFiles", text)
            self.assertIn("!before.candidateFiles.includes(path)", text)
            self.assertIn("method:'DELETE'", text)

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
            self.assertIn("Date.now()+300000", text)
            launcher = (ROOT / "dotfiles/niri/.config/niri/scripts/agent-review").read_text()
            self.assertIn("timeout=FULL_READINESS_TIMEOUT_SECONDS", launcher)
            self.assertGreaterEqual(harness.FULL_READINESS_TIMEOUT_SECONDS, 360)

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
