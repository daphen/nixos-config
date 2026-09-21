#!/usr/bin/env python3
import os, shutil, signal, subprocess, sys, tempfile, time, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / 'dotfiles/hyprland/.config/hypr/scripts/desktop-launch'
CONTROLLER = ROOT / 'dotfiles/hyprland/.config/hypr/scripts/deck-gaming-mode'
class RealFreezerTest(unittest.TestCase):
    def setUp(self):
        if not shutil.which('systemctl') or subprocess.run(
                ['systemctl', '--user', 'show-environment'], capture_output=True).returncode:
            self.skipTest('no live user systemd manager')
        self.temp = tempfile.TemporaryDirectory(prefix='deck-freezer-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.slice = f'deck-freeze-fixture-{os.getpid()}.slice'
        self.real_systemctl = shutil.which('systemctl')
        self._write_adapters()
        self.env = dict(os.environ, HYPR_CANVAS_PROFILE='deck', XDG_RUNTIME_DIR=str(self.root),
                        FIXTURE=str(self.root), FIXTURE_SLICE=self.slice,
                        REAL_SYSTEMCTL=self.real_systemctl, REAL_SYSTEMD_RUN=shutil.which('systemd-run'),
                        REAL_XDG_RUNTIME_DIR=os.environ['XDG_RUNTIME_DIR'],
                        PATH=f'{self.root}:{os.environ["PATH"]}')
        self.processes = []
        self.addCleanup(self._cleanup)
    def _write(self, name, body):
        path = self.root / name
        path.write_text(f'#!{sys.executable}\n' + body)
        path.chmod(0o755)
    def _write_adapters(self):
        self._write('systemctl', r'''
import os, pathlib, subprocess, sys, time
args = sys.argv[1:]
if any(x in ('freeze', 'thaw') for x in args) and 'deck-work.slice' not in args:
    print('refusing non-fixture systemctl mutation', file=sys.stderr); sys.exit(90)
args = [os.environ['FIXTURE_SLICE'] if x == 'deck-work.slice' else x for x in args]
env = dict(os.environ, XDG_RUNTIME_DIR=os.environ['REAL_XDG_RUNTIME_DIR'])
result = subprocess.run([os.environ['REAL_SYSTEMCTL'], *args], env=env, text=True, capture_output=True)
if os.environ.get('PAUSE_AFTER_RUNNING_READ') and 'FreezerState' in args and result.stdout.strip() == 'running':
    root = pathlib.Path(os.environ['FIXTURE']); (root / 'race-read').write_text('1')
    while not (root / 'race-release').exists(): time.sleep(.01)
sys.stdout.write(result.stdout); sys.stderr.write(result.stderr); sys.exit(result.returncode)
''')
        self._write('systemd-run', r'''
import os, subprocess, sys
args = sys.argv[1:]
out = [('--slice=' + os.environ['FIXTURE_SLICE']) if arg == '--slice=deck-work.slice' else arg
       for arg in args]
if not any(x.startswith('--slice=') for x in out): sys.exit(91)
env = dict(os.environ, XDG_RUNTIME_DIR=os.environ['REAL_XDG_RUNTIME_DIR'])
sys.exit(subprocess.run([os.environ['REAL_SYSTEMD_RUN'], *out], env=env).returncode)
''')
        self._write('hyprctl', r'''
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ['-j', 'activeworkspace']: print(json.dumps({'name': 'work'}))
elif args == ['-j', 'clients']: print('[]')
else: print('ok')
''')
        self._write('inputplumber', r'''
import os, pathlib, sys
args = sys.argv[1:]
if args[3] == 'path': print("Current profile path: '/etc/inputplumber/profiles/hyprland-canvas.yaml'")
''')
        self._write('counter-workload', r'''
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
prefix = 'control' if pathlib.Path(sys.argv[0]).name == 'steam' else sys.argv[2]
def loop(name):
    (root / (name + '.pid')).write_text(str(os.getpid()))
    n = 0
    while True:
        n += 1
        if n % 10000 == 0: (root / name).write_text(str(n))
if prefix == 'work':
    pid = os.fork()
    if pid == 0: loop('child')
loop(prefix)
''')
        (self.root / 'steam').symlink_to(self.root / 'counter-workload')
        self._write('deck-gaming-mode', r'''
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(pathlib.Path('/proc/self/cgroup').read_text())
''')
    def _start(self, *args, env=None):
        process = subprocess.Popen(args, env=env or self.env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, text=True)
        self.processes.append(process)
        return process
    def _wait_file(self, name, timeout=3):
        path = self.root / name
        deadline = time.time() + timeout
        while time.time() < deadline:
            if path.exists() and (value := path.read_text()): return int(value)
            time.sleep(.02)
        self.fail(f'{name} did not start')
    def _cleanup(self):
        subprocess.run([self.real_systemctl, '--user', 'thaw', self.slice], capture_output=True)
        subprocess.run([self.real_systemctl, '--user', 'stop', self.slice], capture_output=True)
        try: os.kill(int((self.root / 'control.pid').read_text()), signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError): pass
        for process in self.processes:
            try: process.wait(timeout=1)
            except subprocess.TimeoutExpired: process.kill()
    def test_public_launch_and_controller_freeze_descendants_only(self):
        self._start('bash', str(LAUNCHER), 'counter-workload', str(self.root), 'work')
        self._start('bash', str(LAUNCHER), 'steam', str(self.root))
        self._wait_file('child'); self._wait_file('control')
        escape = self.root / 'escape-cgroup'
        self._start('bash', str(LAUNCHER), 'bash', str(LAUNCHER),
                    'deck-gaming-mode', str(escape)).wait(timeout=5)
        self.assertNotIn(self.slice, escape.read_text())
        self.assertIn('app.slice', escape.read_text())
        race_env = dict(self.env, PAUSE_AFTER_RUNNING_READ='1')
        self._start('bash', str(LAUNCHER), 'counter-workload', str(self.root), 'race', env=race_env)
        self._wait_file('race-read')
        entering = self._start('bash', str(CONTROLLER), 'enter')
        time.sleep(.2)
        self.assertIsNone(entering.poll(), 'Game Mode raced past an in-progress scope start')
        (self.root / 'race-release').write_text('1'); self._wait_file('race'); entering.wait(timeout=8)
        work = self._wait_file('work'); child = self._wait_file('child'); control = self._wait_file('control')
        time.sleep(.2)
        self.assertEqual((work, child), (self._wait_file('work'), self._wait_file('child')))
        self.assertGreater(self._wait_file('control'), control)
        late = self._start('bash', str(LAUNCHER), 'counter-workload', str(self.root), 'late')
        time.sleep(.2)
        self.assertFalse((self.root / 'late').exists(), 'new work ran inside a frozen slice')
        result = subprocess.run(['bash', str(CONTROLLER), 'cleanup'], env=self.env,
                                text=True, capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self._wait_file('late')
        time.sleep(.15)
        self.assertGreater(self._wait_file('work'), work)
        self.assertGreater(self._wait_file('child'), child)
if __name__ == '__main__':
    unittest.main()
