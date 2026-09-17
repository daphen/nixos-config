import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "dotfiles/bin/.local/bin/plan-open"


class PlanOpen(unittest.TestCase):
    def run_case(self, case="ok", socket=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan = root / "plan with spaces.md"
            plan.write_text("# keep exactly this\n")
            program = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]; name=Path(sys.argv[0]).name
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps([name,*a])+'\\n')
case=os.environ['CASE']
if name=='qs':
 if a[0]=='list':print(json.dumps([{'id':'other','pid':1},{'id':'bound','pid':2}]))
 elif a[-1]=='railState':print(json.dumps({'sel':'actor' if (a[2]=='bound' and case!='missing') or case=='ambiguous' else 'another-agent'}))
 elif a[-1]=='nvimSock':print('/run/'+a[2]+'.sock')
 elif a[-1]=='focusLeft':print('consumed')
elif name=='nvim':print('/wrong/file' if case=='refused' else os.environ['PLAN'])
'''
            for name in ["qs", "nvim"]:
                executable = root / name
                executable.write_text(program)
                executable.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("COCKPIT_", "HEIDR_"))}
            env.update(PATH=str(root) + os.pathsep + os.environ["PATH"], CASE=case, PLAN=str(plan), CALLS=str(root / "calls"), COCKPIT_AGENT_NAME="actor")
            if socket:
                env["COCKPIT_NVIM_SOCK"] = socket
            result = subprocess.run(["python3", str(SCRIPT), "/wrong/repository", str(plan)], env=env, capture_output=True, text=True, timeout=5)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
            self.assertEqual(plan.read_text(), "# keep exactly this\n")
            return result, calls

    def test_uses_existing_session_binding_not_cwd(self):
        result, calls = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        editors = [call for call in calls if call[0] == "nvim"]
        self.assertEqual(len(editors), 2)
        self.assertTrue(all(call[2] == "/run/bound.sock" for call in editors))
        self.assertIn("CockpitEdit", editors[0][-1])
        self.assertIn(["qs", "ipc", "-i", "bound", "call", "cockpit", "focusLeft"], calls)
        self.assertIn("Opened", result.stdout)

    def test_explicit_editor_binding_wins(self):
        result, calls = self.run_case(socket="/run/other.sock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call[2] == "/run/other.sock" for call in calls if call[0] == "nvim"))

    def test_missing_or_ambiguous_binding_never_opens_another_editor(self):
        for case in ["missing", "ambiguous"]:
            with self.subTest(case=case):
                result, calls = self.run_case(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "nvim" for call in calls))
                self.assertNotIn("Opened", result.stdout)

    def test_refused_open_is_not_reported_as_success(self):
        result, calls = self.run_case("refused")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("editor did not open", result.stderr)
        self.assertFalse(any(call[-1] == "focusLeft" for call in calls))


if __name__ == "__main__":
    unittest.main()
