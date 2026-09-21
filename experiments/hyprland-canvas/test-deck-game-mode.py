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
    elif args in (['-j', 'clients'], ['clients', '-j']):
        print(json.dumps(state.get('clients', [])))
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
elif name == 'readlink':
    assert args[0] == '-f' and pathlib.Path(args[-1]).parent == pathlib.Path('/etc/inputplumber/profiles')
    print(root / 'profiles' / pathlib.Path(args[-1]).name)
elif name == 'inputplumber':
    if args[3] == 'path':
        print("Current profile path: '%s'" % state['profile'])
    else:
        if state.get('fail') == args[-1]:
            sys.exit(1)
        time.sleep(float(os.environ.get('PROFILE_DELAY', '0')))
        state['profile'] = args[-1]
elif name == 'systemctl':
    args = args[1:] if args[:1] == ['--user'] else args
    action = args[0]
    if action == 'whoami':
        unit = state.get('pids', {}).get(args[1])
        if not unit: sys.exit(1)
        print(unit)
    else:
        unit = args[1]
        units = state.setdefault('units', {})
        if unit not in units:
            if action == 'show' and 'LoadState' in args: print('not-found')
            else: sys.exit(1)
        elif action == 'show':
            prop = args[args.index('-p') + 1]
            print(units[unit].get(prop, ''))
        elif action in ('freeze', 'thaw'):
            if unit != 'deck-work.slice' and not unit.startswith('app-org.chromium.Chromium-fixture'):
                sys.exit(90)
            if state.get('fail') == action + ':' + unit:
                sys.exit(1)
            units[unit]['FreezerState'] = 'frozen' if action == 'freeze' else 'running'
            (root / 'state').write_text(json.dumps(state))
            if action == 'freeze' and state.get('fail') == 'timeout:' + unit: time.sleep(4)
(root / 'state').write_text(json.dumps(state))
'''


class ModeCommandTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='deck-mode-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = dict(os.environ, FIXTURE=str(self.root), XDG_RUNTIME_DIR=str(self.root),
                        PATH=f'{self.root}:{os.environ["PATH"]}')
        for name in ('hyprctl', 'inputplumber', 'busctl', 'systemctl', 'notify-send', 'readlink', 'pkill'):
            path = self.root / name
            path.write_text(f'#!{sys.executable}\n' + MOCK)
            path.chmod(0o755)
        self.configure()

    def configure(self, workspace='1', profile='canvas', fail=None):
        self.write_state({
            'workspace': workspace, 'previous': '1',
            'profile': self.profile(profile), 'fail': fail,
            'clients': [], 'pids': {},
            'units': {'deck-work.slice': {
                'LoadState': 'loaded', 'FreezerState': 'running', 'Slice': ''}},
        })
        (self.root / 'calls').write_text('')
        (self.root / 'deck-gaming-mode.frozen').unlink(missing_ok=True)

    def profile(self, name):
        return str(self.root / 'profiles' / f'hyprland-{name}.yaml')

    def write_state(self, state):
        (self.root / 'state').write_text(json.dumps(state))

    def state(self):
        return json.loads((self.root / 'state').read_text())

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]

    def add_client(self, pid, workspace, unit, slice_name='app.slice', state='running'):
        data = self.state()
        data['clients'].append({'pid': pid, 'workspace': {'name': workspace}})
        data['pids'][str(pid)] = unit
        data['units'][unit] = {
            'LoadState': 'loaded', 'FreezerState': state, 'Slice': slice_name}
        self.write_state(data)

    def run_mode(self, *args, success=True):
        result = subprocess.run(['bash', str(COMMAND), *args], env=self.env,
                                text=True, capture_output=True, timeout=8)
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

    def test_browser_scopes_freeze_but_gaming_browser_is_excluded(self):
        browser = 'app-org.chromium.Chromium-fixture-browser.scope'
        self.add_client(10, 'work', browser)
        self.run_mode('enter')
        self.assertEqual(self.state()['units'][browser]['FreezerState'], 'frozen')
        self.run_mode('return')
        self.assertEqual(self.state()['units'][browser]['FreezerState'], 'running')

        self.configure()
        self.add_client(10, 'work', browser)
        self.add_client(11, 'gaming', browser)
        self.run_mode('enter')
        self.assertEqual(self.state()['units'][browser]['FreezerState'], 'running')

    def test_gaming_window_in_work_slice_blocks_entry(self):
        self.add_client(12, 'gaming', 'fixture-work.scope', 'deck-work.slice')
        self.run_mode('enter', success=False)
        self.assertEqual(self.state()['units']['deck-work.slice']['FreezerState'], 'running')
        self.assertEqual(self.state()['workspace'], '1')

    def test_pre_frozen_unit_is_not_owned_or_thawed(self):
        data = self.state()
        data['units']['deck-work.slice']['FreezerState'] = 'frozen'
        self.write_state(data)
        self.run_mode('enter')
        self.run_mode('return')
        self.assertEqual(self.state()['units']['deck-work.slice']['FreezerState'], 'frozen')

    def test_partial_failure_and_timeout_roll_back_owned_units(self):
        browser = 'app-org.chromium.Chromium-fixture-fail.scope'
        for failure in ('freeze:' + browser, 'timeout:' + browser):
            with self.subTest(failure=failure):
                self.configure(fail=failure)
                self.add_client(13, 'work', browser)
                self.run_mode('enter', success=False)
                units = self.state()['units']
                self.assertEqual(units['deck-work.slice']['FreezerState'], 'running')
                self.assertEqual(units[browser]['FreezerState'], 'running')
                self.assertFalse((self.root / 'deck-gaming-mode.frozen').exists())

    def test_cleanup_thaws_without_compositor_or_input(self):
        data = self.state()
        data['units']['deck-work.slice']['FreezerState'] = 'frozen'
        self.write_state(data)
        (self.root / 'deck-gaming-mode.frozen').write_text(
            'deck-work.slice\napp-org.chromium.Chromium-fixture-gone.scope\n')
        (self.root / 'hyprctl').unlink()
        (self.root / 'inputplumber').unlink()
        self.run_mode('cleanup')
        self.assertEqual(self.state()['units']['deck-work.slice']['FreezerState'], 'running')
        self.assertFalse((self.root / 'deck-gaming-mode.frozen').exists())

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
