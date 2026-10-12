#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

SCRIPTS = Path(__file__).resolve().parents[2] / "dotfiles/hyprland/.config/hypr/scripts"


def _wait(check):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError("hotplug helper did not reach the expected state")


with tempfile.TemporaryDirectory(prefix="hotplug-test-") as directory:
    root = Path(directory)
    for name in ("hyprland-hotplug-handler", "hypr-dispatch"):
        shutil.copy2(SCRIPTS / name, root / name)
    mock = root / "hyprctl"
    mock.write_text("""#!/usr/bin/env python3
import os, sys
from pathlib import Path
p = Path(os.environ['FIXTURE'])
if (p / 'gone').exists():
    sys.exit(4)
if sys.argv[1] == 'eval':
    with (p / 'moves').open('a') as f:
        f.write(sys.argv[2] + '\\n')
else:
    print((p / sys.argv[-1]).read_text())
""")
    mock.chmod(0o755)
    env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", FIXTURE=str(root),
               XDG_RUNTIME_DIR=str(root), HYPRLAND_INSTANCE_SIGNATURE="current")
    external = [{"name": "eDP-1", "width": 3840, "height": 2400},
                {"name": "DP-1", "width": 3840, "height": 2160}]
    (root / "monitors").write_text(json.dumps(external))
    (root / "workspaces").write_text(json.dumps([
        {"name": "1", "monitor": "eDP-1", "windows": 3},
        {"name": "2", "monitor": "eDP-1", "windows": 0},
        {"name": "3", "monitor": "DP-1", "windows": 2}]))
    moves = root / "moves"
    processes = []
    try:
        with (root / "hyprland-hotplug-handler-old.lock").open("w") as old, \
                (root / "hyprland-hotplug-handler.lock").open("w") as legacy:
            fcntl.flock(old, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(legacy, fcntl.LOCK_EX | fcntl.LOCK_NB)
            helper = subprocess.Popen([root / "hyprland-hotplug-handler"], env=env)
            processes.append(helper)
            _wait(lambda: moves.exists())
            expected = 'hl.dispatch(hl.dsp.workspace.move({ workspace = "1", monitor = "DP-1" }))'
            assert moves.read_text().splitlines() == [expected]
            duplicate = subprocess.run([root / "hyprland-hotplug-handler"], env=env, timeout=3)
            assert duplicate.returncode == 0
            time.sleep(1.1)
            assert moves.read_text().splitlines() == [expected]
            (root / "monitors").write_text(json.dumps(external[:1]))
            time.sleep(1.2)
            assert moves.read_text().splitlines() == [expected]
            (root / "monitors").write_text(json.dumps(external))
            _wait(lambda: len(moves.read_text().splitlines()) == 2)
            assert moves.read_text().splitlines() == [expected, expected]
            (root / "gone").touch()
            assert helper.wait(timeout=3) == 0
            with (root / "hyprland-hotplug-handler-current.lock").open("r") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (root / "gone").unlink()
            successor = subprocess.Popen([root / "hyprland-hotplug-handler"], env=env)
            processes.append(successor)
            _wait(lambda: len(moves.read_text().splitlines()) == 3)
            (root / "gone").touch()
            assert successor.wait(timeout=3) == 0
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=3)
print("PASS: populated transfer, empty exclusion, disconnect/reconnect, duplicate lock, old-session isolation, exit and restart")
