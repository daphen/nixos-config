#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ.get("ROSTER_SCRIPT", Path(__file__).resolve().parents[1] / "dotfiles/hyprland/.config/hypr/scripts/cockpit-rail-roster"))


class RosterRoute(unittest.TestCase):
    def route(self, focused):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copy2(SCRIPT, root / "roster")
            clients = [
                dict(address="other", title="cockpit-qs other", workspace=dict(name="2", address="2", type="numbered"), focusHistoryID=1),
                dict(address="work", title="cockpit-qs work", workspace=dict(name="1", address="1", type="numbered"), focusHistoryID=3),
                dict(address="personal", title="cockpit-qs personal", workspace=dict(name="1", address="1", type="numbered"), focusHistoryID=2),
                dict(address="browser", title="Browser", workspace=dict(name="1", address="1", type="numbered"), focusHistoryID=0),
            ]
            tools = {
                "hyprctl": "import json,os,sys\nc=json.loads(os.environ['CLIENTS']); print(json.dumps(c if sys.argv[-1]=='clients' else {'address':os.environ['FOCUSED']}))\n",
                "qs": "import json,os,sys\na=sys.argv; c=json.loads(os.environ['CLIENTS']); names={w['address']:w['title'] for w in c if w['title'].startswith('cockpit-qs')}\nif a[1]=='list': print(json.dumps([{'id':k,'pid':1} for k in names]))\nelif a[-1]=='title': print(names[a[3]])\nelse:\n with open(os.environ['LOG'],'a') as f: f.write(a[3]+' '+a[-1]+'\\n')\n print('landed')\n",
                "hypr-dispatch": "import os,sys\nwith open(os.environ['LOG'],'a') as f: f.write('focus '+sys.argv[-1]+'\\n')\n",
            }
            for name, body in tools.items():
                p = root / name
                p.write_text("#!/usr/bin/env python3\n" + body)
                p.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", XDG_RUNTIME_DIR=tmp, CLIENTS=json.dumps(clients), FOCUSED=focused, LOG=str(root / "log"))
            subprocess.run(["bash", str(root / "roster")], env=env, check=True, timeout=6)
            return (root / "log").read_text().splitlines()

    def test_focused_private_uses_its_toggle(self):
        self.assertEqual(self.route("personal"), ["personal rosterToggle"])

    def test_focused_work_uses_its_toggle(self):
        self.assertEqual(self.route("work"), ["work rosterToggle"])

    def test_external_app_uses_recent_cockpit_on_same_canvas_workspace(self):
        self.assertEqual(self.route("browser"), ["focus address:personal", "personal rosterHop"])


if __name__ == "__main__":
    unittest.main()
