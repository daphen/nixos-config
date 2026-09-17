#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ROOT / 'dotfiles/hyprland/.config/hypr/scripts/deck-gaming-mode'
MOCK = r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FIXTURE'])
state = json.loads((root / 'state').read_text())
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')
if name == 'hyprctl':
    if args == ['-j', 'activeworkspace']:
        print(json.dumps({'name': state['workspace']}))
    elif 'hl.dsp.focus' in args[-1]:
        if state.get('fail') == 'focus':
            print('error: focus rejected')
        else:
            state['workspace'], state['previous'] = (
                ('gaming', state['workspace']) if 'name:gaming' in args[-1]
                else (state['previous'], state['workspace']))
            print('ok')
    else:
        print('error: launch rejected' if state.get('fail') == 'launch' else 'ok')
elif name == 'inputplumber':
    if args[3] == 'path':
        print("Current profile path: '%s'" % state['profile'])
    else:
        if state.get('fail') == args[-1]:
            sys.exit(1)
        time.sleep(float(os.environ.get('PROFILE_DELAY', '0')))
        state['profile'] = args[-1]
(root / 'state').write_text(json.dumps(state))
'''


class ModeCommandTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='deck-mode-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = dict(os.environ, FIXTURE=str(self.root), XDG_RUNTIME_DIR=str(self.root),
                        PATH=f'{self.root}:{os.environ["PATH"]}')
        for name in ('hyprctl', 'inputplumber', 'busctl'):
            path = self.root / name
            path.write_text(f'#!{sys.executable}\n' + MOCK)
            path.chmod(0o755)
        self.configure()

    def configure(self, workspace='1', profile='canvas', fail=None):
        self.write_state({'workspace': workspace, 'previous': '1',
                          'profile': self.profile(profile), 'fail': fail})
        (self.root / 'calls').write_text('')

    def profile(self, name):
        return f'/etc/inputplumber/profiles/hyprland-{name}.yaml'

    def write_state(self, state):
        (self.root / 'state').write_text(json.dumps(state))

    def state(self):
        return json.loads((self.root / 'state').read_text())

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]

    def run_mode(self, *args, success=True):
        result = subprocess.run(['bash', str(COMMAND), *args], env=self.env,
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode == 0, success, result.stderr + result.stdout)

    def test_enter_and_return_preserve_workspace_history(self):
        self.configure(workspace='work-project')
        self.run_mode('tap')
        self.assertEqual(self.state()['workspace'], 'gaming')
        self.assertEqual(self.state()['profile'], self.profile('gaming'))
        self.assertTrue(any('steam://open/bigpicture' in str(call) for call in self.calls()))
        self.run_mode('enter')
        self.assertEqual(self.state()['previous'], 'work-project')
        self.run_mode('return')
        self.assertEqual(self.state()['workspace'], 'work-project')
        self.assertEqual(self.state()['profile'], self.profile('canvas'))
        self.assertFalse(any(call[0] == 'busctl' for call in self.calls()))

    def test_gaming_tap_forwards_one_guide_chord(self):
        self.configure('gaming', 'gaming')
        self.run_mode('tap')
        calls = [call for call in self.calls() if call[0] == 'busctl']
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-4:], ['SendButtonChord', 'as', '1', 'Gamepad:Button:Guide'])
        self.assertEqual(self.state()['workspace'], 'gaming')
        self.assertFalse(any(call[0] == 'inputplumber' for call in self.calls()))

    def test_return_from_work_does_nothing(self):
        self.run_mode('return')
        self.assertEqual(len(self.calls()), 1)

    def test_profile_failure_does_not_switch_or_launch(self):
        for workspace, old, target, action in [('1', 'canvas', 'gaming', 'enter'),
                                              ('gaming', 'gaming', 'canvas', 'return')]:
            with self.subTest(action=action):
                self.configure(workspace, old, self.profile(target))
                self.run_mode(action, success=False)
                self.assertEqual(self.state()['workspace'], workspace)
                self.assertEqual(self.state()['profile'], self.profile(old))
                self.assertFalse(any(call[:2] == ['hyprctl', 'dispatch'] for call in self.calls()))

    def test_focus_failure_restores_input_profile(self):
        for workspace, old, action in [('1', 'canvas', 'enter'), ('gaming', 'gaming', 'return')]:
            with self.subTest(action=action):
                self.configure(workspace, old, 'focus')
                self.run_mode(action, success=False)
                self.assertEqual(self.state()['profile'], self.profile(old))
                self.assertEqual(self.state()['workspace'], workspace)

    def test_rejected_launch_restores_work(self):
        self.configure(fail='launch')
        self.run_mode('enter', success=False)
        self.assertEqual(self.state()['workspace'], '1')
        self.assertEqual(self.state()['profile'], self.profile('canvas'))

    def test_return_waits_for_an_in_progress_entry(self):
        self.env['PROFILE_DELAY'] = '0.3'
        with subprocess.Popen(['bash', str(COMMAND), 'enter'], env=self.env) as entering:
            for _ in range(100):
                if any(call[-1] == self.profile('gaming') for call in self.calls()):
                    break
                time.sleep(.01)
            else:
                self.fail('entry never began loading the gaming profile')
            self.run_mode('return')
            self.assertEqual(entering.wait(timeout=5), 0)
        self.assertEqual(self.state()['workspace'], '1')
        self.assertEqual(self.state()['profile'], self.profile('canvas'))

    def test_manual_workspace_change_syncs_once(self):
        self.configure('1', 'gaming')
        self.run_mode('sync')
        self.run_mode('sync')
        loads = [call for call in self.calls() if call[0] == 'inputplumber' and call[4] == 'load']
        self.assertEqual(len(loads), 1)
        self.assertEqual(self.state()['profile'], self.profile('canvas'))


if __name__ == '__main__':
    unittest.main()
