#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('zoom', Path(__file__).with_name('test-canvas-zoom.py'))
zoom = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zoom)


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.args = ['zoom', '--binary', sys.executable, '--parent-binary', sys.executable,
                     '--weston', sys.executable, '--bootstrap-niri', sys.executable,
                     '--output', str(self.root / 'out'), '--cpu', '2', '--parent-cpu', '0', '--weston-cpu', '1']

    def test_cli_enters_bounded_service_before_launch(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, 'argv', self.args), \
                patch.object(zoom.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)) as run, \
                patch.object(zoom.subprocess, 'Popen') as launch, self.assertRaises(SystemExit) as exit:
            zoom.main()
        self.assertEqual(exit.exception.code, 0)
        command = run.call_args.args[0]
        for item in ('--property=CPUQuota=150%', '--property=RuntimeMaxSec=180s', '--property=KillMode=control-group',
                     '--property=RestrictRealtime=yes', '--setenv=HYPRLAND_NO_RT=1'):
            self.assertIn(item, command)
        launch.assert_not_called()

    def test_cli_rejects_protocol_shim(self):
        with patch.object(sys, 'argv', self.args + ['--weston-shim', '/old.so']), \
                patch.object(zoom.subprocess, 'Popen') as launch, self.assertRaises(SystemExit):
            zoom.main()
        launch.assert_not_called()

    def test_cli_rejects_preload(self):
        with patch.dict(os.environ, {'LD_PRELOAD': '/old.so'}, clear=True), patch.object(sys, 'argv', self.args), \
                patch.object(zoom.subprocess, 'run') as run, self.assertRaises(SystemExit):
            zoom.main()
        run.assert_not_called()

    def test_cli_cannot_bypass_service_with_environment(self):
        with patch.dict(os.environ, {'CANVAS_ZOOM_UNIT': 'canvas-zoom-fake'}, clear=True), patch.object(sys, 'argv', self.args), \
                patch.object(zoom.subprocess, 'Popen') as launch, self.assertRaises((SystemExit, FileNotFoundError)):
            zoom.main()
        launch.assert_not_called()

    def exercise_watchdog(self, message='', policy=os.SCHED_OTHER, runaway=False, deadline=False, exited=False):
        runtime = self.root / 'runtime'
        runtime.mkdir()
        real_read = Path.read_text
        unit = 'canvas-zoom-test'
        started = time.monotonic()
        processes = []

        def read(path, *args, **kwargs):
            if path == Path('/proc/self/cgroup'):
                return f'0::/{unit}.service\n'
            if str(path).startswith('/sys/fs/cgroup/'):
                if path.name == 'cgroup.procs':
                    return str(os.getpid())
                return '150000 100000' if path.name == 'cpu.max' else 'usage_usec 0\n'
            text = real_read(path, *args, **kwargs)
            if runaway and str(path).startswith('/proc/') and path.name == 'stat':
                prefix, tail = text.rsplit(')', 1)
                fields = tail.split()
                fields[11] = str(int((time.monotonic() - started) * os.sysconf('SC_CLK_TCK')))
                fields[12] = '0'
                return prefix + ') ' + ' '.join(fields)
            return text

        def launch(command, **kwargs):
            p = Mock(pid=[os.getpid(), os.getppid(), 1][len(processes)], args=command, returncode=None)
            p.poll.return_value = 1 if exited else None
            p.wait.return_value = 0
            processes.append(p)
            kwargs['stdout'].write(message)
            kwargs['stdout'].flush()
            self.assertEqual(kwargs['env']['HYPRLAND_NO_RT'], '1')
            self.assertNotIn('LD_PRELOAD', kwargs['env'])
            self.assertTrue(kwargs['start_new_session'])
            return p

        def wait(predicate, children):
            if not message and not deadline and not exited and len(processes) < 3:
                return 'wayland-0'
            until = time.monotonic() + 4
            while not killed.called and time.monotonic() < until:
                time.sleep(.02)
            raise RuntimeError('mock fixture wait ended')

        def counters(pid):
            return {'time': time.monotonic(), 'gfx_ns': 0,
                    'cpu_ticks': int((time.monotonic() - started) * os.sysconf('SC_CLK_TCK') * (1 if runaway else 0))}

        initial_time = iter([0])
        clock = types.SimpleNamespace(monotonic=lambda: next(initial_time, 200), sleep=time.sleep) if deadline else zoom.time
        with patch.dict(os.environ, {'CANVAS_ZOOM_UNIT': unit}, clear=True), patch.object(sys, 'argv', self.args), \
                patch.object(Path, 'read_text', read), patch.object(zoom.tempfile, 'mkdtemp', return_value=str(runtime)), \
                patch.object(zoom.subprocess, 'Popen', side_effect=launch), patch.object(zoom.r, 'wait', side_effect=wait), \
                patch.object(zoom.r, 'counters', side_effect=counters), patch.object(zoom.os, 'kill') as killed, \
                patch.object(zoom.os, 'killpg') as groups, patch.object(zoom.os, 'sched_getscheduler', return_value=policy), \
                patch.object(zoom, 'time', clock), self.assertRaises(RuntimeError):
            zoom.main()
        killed.assert_called_once_with(os.getpid(), signal.SIGTERM)
        result = json.loads((self.root / 'out/result.json').read_text())
        self.assertFalse(result['passed'])
        self.assertIn('safety_failure', result)
        self.assertEqual(groups.call_count, 2 * len(processes))
        return result['safety_failure']

    def exercise_direct(self, early_attach=False):
        runtime = self.root / 'runtime'
        instance = runtime / 'hypr' / 'child'
        instance.mkdir(parents=True)
        (instance / 'hyprland.log').write_text('Renderer: AMD mocked renderer\n')
        real_read = Path.read_text
        quota_reads = 0
        launches = []

        def read(path, *args, **kwargs):
            nonlocal quota_reads
            if path == Path('/proc/self/cgroup'):
                return '0::/canvas-zoom-test.service\n'
            if str(path).startswith('/sys/fs/cgroup/'):
                if path.name == 'cpu.max':
                    return '150000 100000'
                if path.name == 'cgroup.procs':
                    return str(os.getpid())
                quota_reads += 1
                return f'usage_usec 0\nnr_throttled {quota_reads}\nthrottled_usec {quota_reads}\n'
            return real_read(path, *args, **kwargs)

        def launch(command, **kwargs):
            launches.append((command, kwargs))
            p = Mock(pid=9 + len(launches), args=command, returncode=None)
            p.poll.return_value = None
            p.wait.return_value = 0
            if '--socket' in command:
                self.assertEqual(kwargs['env']['WAYLAND_DISPLAY'], 'wayland-mock')
                kwargs['stdout'].write('get_xdg_surface(new id xdg_surface#12, wl_surface#11)\n')
                if early_attach:
                    kwargs['stdout'].write('-> wl_surface#11.attach(wl_buffer#15, 0, 0)\n')
                kwargs['stdout'].write('-> xdg_surface#12.ack_configure(1)\n')
                kwargs['stdout'].flush()
            return p

        def ipc(instance, command):
            if command == 'configerrors':
                return ''
            if command == 'j/monitors':
                return '[{"name":"WAYLAND-1","width":800,"height":1280,"transform":3}]'
            if command == 'j/clients':
                return '[]'
            if command.startswith('j/getoption'):
                return '{"bool":true}' if command.endswith(':canvas_lens') else '{"float":0.75}'
            return 'ok'

        waits = [True, 'wayland-mock', runtime / 'niri.mock.sock', {}, instance, True, True, True, True]
        with patch.dict(os.environ, {'CANVAS_ZOOM_UNIT': 'canvas-zoom-test'}, clear=True), \
                patch.object(sys, 'argv', self.args + ['--measure-only', '--clients', '2', '--cycles', '1', '--repeats', '1']), \
                patch.object(Path, 'read_text', read), patch.object(zoom.tempfile, 'mkdtemp', return_value=str(runtime)), \
                patch.object(zoom.subprocess, 'Popen', side_effect=launch), patch.object(zoom.subprocess, 'run'), \
                patch.object(zoom.r, 'wait', side_effect=waits), patch.object(zoom.r, 'ipc', side_effect=ipc), \
                patch.object(zoom.r, 'sha', return_value='mocked'), patch.object(zoom.time, 'sleep'), \
                patch.object(zoom.r, 'counters', return_value={'time': 1, 'cpu_ticks': 0, 'gfx_ns': 0}), \
                patch.object(zoom.os, 'killpg'), patch.object(zoom.os, 'kill'), \
                patch.object(zoom.os, 'sched_getaffinity', side_effect=lambda pid: {10: {1}, 11: {0}, 12: {2}}[pid]), \
                self.assertRaises((RuntimeError, AssertionError)) as failure:
            zoom.main()
        self.assertEqual(len([command for command, _ in launches if '--socket' in command]), 1)
        self.assertEqual(launches[2][0][launches[2][0].index('--socket') + 1], 'candidate')
        result = json.loads((self.root / 'out/result.json').read_text())
        self.assertFalse(result['passed'])
        self.assertEqual(result['trials'], [])
        return str(failure.exception)

    def test_direct_measurement_has_no_bridge_and_rejects_throttling(self):
        self.assertIn('quota', self.exercise_direct())

    def test_direct_measurement_rejects_buffer_before_ack(self):
        self.assertIn('before initial configure', self.exercise_direct(early_attach=True))

    def test_cache_checks_require_two_output_case(self):
        with patch.object(sys, 'argv', self.args + ['--cache-checks']), patch.object(zoom.subprocess, 'Popen') as launch, self.assertRaises(SystemExit):
            zoom.main()
        launch.assert_not_called()

    def test_two_output_case_cannot_disable_effects(self):
        with patch.object(sys, 'argv', self.args + ['--other-output-damage', '--screen', 'canvas_lens', '--repeats', '1']), \
                patch.object(zoom.subprocess, 'Popen') as launch, self.assertRaises(SystemExit):
            zoom.main()
        launch.assert_not_called()

    def test_protocol_error_is_fatal(self):
        self.assertIn('error in client communication', self.exercise_watchdog('libwayland: error in client communication (pid 1)\n'))

    def test_unconfigured_surface_is_fatal(self):
        self.assertIn('error', self.exercise_watchdog('xdg_surface#12: error 3: xdg_surface has never been configured\n'))

    def test_rt_acquisition_log_is_fatal(self):
        self.assertIn('Gained realtime scheduling', self.exercise_watchdog('Gained realtime scheduling via rtkit\n'))

    def test_rt_budget_log_is_fatal(self):
        self.assertIn('Realtime budget exceeded', self.exercise_watchdog('Realtime budget exceeded (SIGXCPU), dropping realtime scheduling\n'))

    def test_actual_rt_policy_is_fatal(self):
        self.assertIn('acquired realtime', self.exercise_watchdog(policy=os.SCHED_RR))

    def test_cpu_runaway_is_fatal(self):
        self.assertIn('sustained >80% CPU', self.exercise_watchdog(runaway=True))

    def test_child_exit_is_fatal(self):
        self.assertIn('child exited unexpectedly', self.exercise_watchdog(exited=True))

    def test_deadline_is_fatal(self):
        self.assertIn('deadline', self.exercise_watchdog(deadline=True))


if __name__ == '__main__':
    unittest.main()
