#!/usr/bin/env python3
"""Measure public canvas zoom on a private hardware-backed Weston output."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rendering', ROOT / 'test-canvas-rendering.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def main():
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    signal.signal(signal.SIGINT, signal.default_int_handler)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-binary', type=Path, help='Only needed for input/lock/lifecycle regression capture')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--weston', type=Path, required=True)
    parser.add_argument('--bootstrap-niri', type=Path, required=True)
    parser.add_argument('--pilot', action='store_true', help='Transport and idle-health check only; no zoom workload')
    parser.add_argument('--measure-only', action='store_true', help='Measure through Niri directly; omit bridge-dependent regressions')
    parser.add_argument('--other-output-damage', action='store_true', help='A overview with an updating GTK window on ordinary headless B')
    parser.add_argument('--cache-checks', action='store_true', help='Public two-output cache/lifecycle checks instead of timed trials')
    parser.add_argument('--screen', choices=('control', 'canvas_lens', 'canvas_backdrop_blur', 'canvas_parallax_strength'),
                        help='Unchanged A/A control or baseline/disabled/baseline diagnostic; lens retains native zoom')
    parser.add_argument('--lens-condition', choices=('on', 'off'), help='One fresh-instance control phase; set the public lens option before scene setup')
    parser.add_argument('--repeats', type=int, default=4)
    parser.add_argument('--cycles', type=int, default=6)
    parser.add_argument('--clients', type=int, default=4)
    parser.add_argument('--damage', choices=('partial', 'full'))
    parser.add_argument('--two-rows', action='store_true')
    parser.add_argument('--motion', choices=('zoom', 'pan'), default='zoom')
    parser.add_argument('--lifecycle', action='store_true')
    parser.add_argument('--input-name', choices=('InputPlumber Mouse', 'Generic Test Mouse'))
    parser.add_argument('--input-name-shim', type=Path)
    parser.add_argument('--input-keys', type=Path)
    parser.add_argument('--transform', type=int, choices=(0, 3), default=3)
    parser.add_argument('--size', type=int, nargs=2, metavar=('WIDTH', 'HEIGHT'))
    parser.add_argument('--scale', type=float, default=1)
    parser.add_argument('--refresh', type=int, default=90)
    parser.add_argument('--profile', choices=('deck', 'workstation'), default='deck')
    parser.add_argument('--reserved-top', type=int, default=0)
    parser.add_argument('--native-headless', action='store_true', help='Full-size native headless measurement with small Wayland bootstrap outputs')
    parser.add_argument('--cpu', type=int, required=True)
    parser.add_argument('--parent-cpu', type=int, required=True)
    parser.add_argument('--weston-cpu', type=int, required=True)
    args = parser.parse_args()
    direct = args.pilot or args.screen or args.measure_only or args.other_output_damage or args.native_headless
    if args.native_headless and (args.other_output_damage or args.lifecycle or args.input_name):
        parser.error('native-headless profiling uses one measured output without ablations or extra outputs')
    if args.cache_checks and (not args.other_output_damage or args.clients < 2):
        parser.error('--cache-checks needs --other-output-damage and at least two A clients')
    if args.other_output_damage and args.screen:
        parser.error('two-output cache testing does not disable visual effects')
    if not direct and not args.parent_binary:
        parser.error('regression capture requires --parent-binary; measurements use --measure-only')
    if direct and (args.lifecycle or args.input_name):
        parser.error('input/lifecycle checks require the regression bridge, not a measurement run')
    if not (1 <= args.clients <= 16 and 1 <= args.cycles <= 10 and 1 <= args.repeats <= 4):
        parser.error('bounded runs require 1–16 clients, 1–10 cycles and 1–4 repeats')
    if args.lens_condition and args.screen != 'control':
        parser.error('--lens-condition requires --screen control')
    if args.screen and args.repeats != 1:
        parser.error('screening uses one baseline/diagnostic/baseline sequence; pass --repeats 1')
    if 'LD_PRELOAD' in os.environ:
        parser.error('LD_PRELOAD is forbidden: use real supported Wayland protocols')
    if not os.environ.get('CANVAS_ZOOM_UNIT'):
        unit = 'canvas-zoom-' + uuid.uuid4().hex
        remaining = min(180, int(float(os.environ['CANVAS_ZOOM_DEADLINE']) - time.time()) - 3) if 'CANVAS_ZOOM_DEADLINE' in os.environ else 180
        if remaining < 10:
            parser.error('approved window is ending; refusing another run')
        command = ['systemd-run', '--user', '--wait', '--pipe', '--collect', '--service-type=exec', '--unit=' + unit,
                   '--working-directory=' + os.getcwd(),
                   '--property=CPUQuota=150%', '--property=CPUQuotaPeriodSec=100ms', f'--property=RuntimeMaxSec={remaining}s',
                   '--property=TimeoutStopSec=2s', '--property=KillMode=control-group', '--property=NoNewPrivileges=yes',
                   '--property=RestrictRealtime=yes', '--property=LimitRTPRIO=0', '--property=Nice=10',
                   '--setenv=CANVAS_ZOOM_UNIT=' + unit, '--setenv=HYPRLAND_NO_RT=1']
        for key in ('PATH', 'PYTHONPATH', 'GI_TYPELIB_PATH', 'LD_LIBRARY_PATH', 'XDG_DATA_DIRS', 'DBUS_SESSION_BUS_ADDRESS', 'CANVAS_ZOOM_DEADLINE'):
            if key in os.environ:
                command.append('--setenv=' + key + '=' + os.environ[key])
        raise SystemExit(subprocess.run(command + [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]], check=False).returncode)
    group = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().strip().split('::', 1)[1].lstrip('/')
    quota, period = (group / 'cpu.max').read_text().split()
    if group.name != os.environ['CANVAS_ZOOM_UNIT'] + '.service' or quota == 'max' or int(quota) / int(period) > 1.5:
        parser.error('refusing graphics outside the bounded canvas-zoom service')
    assert not args.lifecycle or (args.clients == 16 and args.two_rows and args.transform == 3)
    assert not args.input_name or (args.input_name_shim and args.input_keys)
    args.output.mkdir(parents=True, exist_ok=False)
    width, height = args.size or ((800, 1280) if args.transform == 3 else (1280, 800))
    boot_w, boot_h, boot_scale, boot_transform, boot_hz, boot_top = (1280, 800, 1, 0, 60, 0) if args.native_headless else (width, height, args.scale, args.transform, args.refresh, args.reserved_top)
    measured_output = 'HEADLESS-1' if args.native_headless else 'WAYLAND-1'
    runtime = Path(tempfile.mkdtemp(prefix='cz-'))
    config = ROOT.parents[1] / 'dotfiles/hyprland/.config/hypr/hyprland.lua'
    wrapper = args.output / 'hyprland.lua'
    wrapper.write_text('package.path=' + json.dumps(str(config.parent / '?.lua') + ';') + '..package.path\n'
                       'local on=hl.on\nhl.on=function(e,cb) if e~="hyprland.start" then return on(e,cb) end end\n'
                       'dofile(' + json.dumps(str(config)) + ')\nhl.on=on\n'
                       'hl.config({misc={disable_splash_rendering=true},debug={disable_logs=false}})\n'
                       f'hl.monitor({{output="WAYLAND-1",mode="{boot_w}x{boot_h}@{boot_hz}",scale={boot_scale},transform={boot_transform},reserved={{top={boot_top}}},disabled=true}})\n')
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(args.output / 'state'),
               XDG_CONFIG_HOME=str(args.output / 'config'), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE=args.profile,
               HYPR_SCRIPTS=str(args.output / 'missing') + '/', HYPRLAND_NO_RT='1')
    for key in ('WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NIRI_SOCKET', 'NIRI_CONFIG', 'SWAYSOCK', 'NOTIFY_SOCKET'):
        env.pop(key, None)
    processes, logs = [], []

    def power_state():
        return {p.name: {k: (p / k).read_text().strip() for k in ('type', 'online', 'status', 'capacity', 'capacity_level') if (p / k).exists()}
                for p in Path('/sys/class/power_supply').glob('*')}

    def thermal_state():
        return {str(p): p.read_text().strip() for p in Path('/sys/class/hwmon').glob('hwmon*/temp*_input')}

    initial_power = power_state()
    power_identity = lambda state: {name: (values.get('online'), values.get('status')) for name, values in state.items()}
    result = {'passed': False, 'trials': [], 'captures': {}, 'binary': r.sha(args.binary),
              'parent_binary': r.sha(args.parent_binary) if not direct else None, 'runner': r.sha(__file__), 'config': {str(p.relative_to(config.parent)): r.sha(p) for p in config.parent.rglob('*.lua')},
              'weston': r.sha(args.weston), 'bootstrap_niri': r.sha(args.bootstrap_niri), 'cycles': args.cycles, 'repeats': args.repeats,
              'screen': args.screen, 'pilot': args.pilot, 'safety_samples': [], 'runtime': str(runtime),
              'requested_output': {'size': [width, height], 'scale': args.scale, 'refresh': args.refresh, 'transform': args.transform, 'profile': args.profile, 'reserved_top': args.reserved_top},
              'other_output_damage': args.other_output_damage, 'cache_checks': args.cache_checks,
              'native_headless': args.native_headless, 'frame_counter': 'CZFRAME render calls' if args.native_headless else 'nested Wayland commits',
              'power_initial': initial_power, 'thermal_initial': thermal_state(),
              'measurement': 'Private headless GL; total work per fixed transitions. Nested commit gaps include settled waits; not render tails, presentation or Deck FPS.',
              'platform_profile': Path('/sys/firmware/acpi/platform_profile').read_text().strip(),
              'cpus': {'candidate': args.cpu, 'bridge': args.parent_cpu, 'weston': args.weston_cpu},
              'workload': {'clients': args.clients, 'damage': args.damage, 'two_rows': args.two_rows, 'motion': args.motion, 'lifecycle': args.lifecycle},
              'client_fixture': r.sha(ROOT / 'test-canvas-visuals.py')}
    assert len(set(result['cpus'].values())) == 3
    affinity = {'compositor.log': args.cpu, 'bridge.log': args.parent_cpu, 'parent.log': args.weston_cpu,
                'bootstrap.log': args.parent_cpu if direct else args.weston_cpu}
    listener = socket.socket(socket.AF_UNIX)
    bridge_listener = socket.socket(socket.AF_UNIX)
    stopping = threading.Event()
    watched = []
    expected_exits = set()
    measuring = threading.Event()

    def cpu_stat():
        return {key: int(value) for key, value in (line.split() for line in (group / 'cpu.stat').read_text().splitlines())}

    def gpu_clients():
        clients = {}
        for pid in (group / 'cgroup.procs').read_text().split():
            for path in Path(f'/proc/{pid}/fdinfo').glob('*'):
                try:
                    info = path.read_text()
                except FileNotFoundError:
                    continue
                identity = re.search(r'drm-client-id:\s*(\d+)', info)
                engine = re.search(r'drm-engine-gfx:\s*(\d+)', info)
                device = re.search(r'drm-pdev:\s*(\S+)', info)
                if identity and engine and device:
                    clients[device[1] + ':' + identity[1]] = {'pid': int(pid), 'gfx_ns': int(engine[1]), 'fdinfo': info}
        return clients

    fatal = re.compile(r'error in client communication|(?:wl_display|xdg_\w+|wl_registry)[^\n]*(?:error|failed)|'
                       r'protocol error|Gained realtime scheduling|Realtime budget exceeded|SIGXCPU|'
                       r'Lost connection to|failed to read Wayland events|Error dispatching', re.I)

    def watchdog():
        offsets, tails, previous = {}, {}, {}
        started = time.monotonic()
        last_throttle = cpu_stat()
        while not stopping.wait(.2):
            try:
                now = time.monotonic()
                if now - started > 165 or ('CANVAS_ZOOM_DEADLINE' in os.environ and time.time() >= float(os.environ['CANVAS_ZOOM_DEADLINE']) - 3):
                    raise RuntimeError('hard harness deadline reached')
                paths = list(args.output.glob('*.log')) + list((runtime / 'hypr').glob('*/hyprland.log'))
                for path in paths:
                    with path.open(errors='replace') as f:
                        f.seek(offsets.get(path, 0))
                        text = f.read()
                        offsets[path] = f.tell()
                    text = tails.get(path, '') + text
                    tails[path] = text[-256:]
                    if match := fatal.search(text):
                        raise RuntimeError(f'{path.name}: {match[0]}')
                for p in tuple(processes):
                    if p not in expected_exits and p.poll() is not None:
                        raise RuntimeError(f'child exited unexpectedly: {p.args}')
                current_power = power_state()
                if power_identity(current_power) != power_identity(initial_power):
                    raise RuntimeError('AC/battery status changed; fresh power controls required')
                if any(p.get('capacity_level', '').lower() in ('low', 'critical') for p in current_power.values()):
                    raise RuntimeError('OS reports low/critical battery; stopping')
                current_cpu = cpu_stat()
                if measuring.is_set() and any(current_cpu[k] > last_throttle[k] for k in ('nr_throttled', 'throttled_usec')):
                    raise RuntimeError('CPU quota throttled a timed trial; measurement invalid')
                last_throttle = current_cpu
                sample = {'time': now, 'processes': {}, 'cpu_ticks': {}, 'policies': {}, 'cgroup_cpu': current_cpu, 'gpu_clients': gpu_clients(),
                          'power': current_power, 'thermal': thermal_state()}
                for pid in map(int, (group / 'cgroup.procs').read_text().split()):
                    try:
                        policies = set()
                        for task in Path(f'/proc/{pid}/task').iterdir():
                            policy = os.sched_getscheduler(int(task.name))
                            policies.add(policy)
                            if policy not in (os.SCHED_OTHER, os.SCHED_BATCH, os.SCHED_IDLE):
                                raise RuntimeError(f'PID {pid} acquired realtime scheduling: {policy}')
                        sample['policies'][pid] = sorted(policies)
                        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                    ticks = int(fields[11]) + int(fields[12])
                    sample['cpu_ticks'][pid] = ticks
                    busy_since = None
                    if pid in previous:
                        before_time, before_ticks, busy_since = previous[pid]
                        duty = (ticks - before_ticks) / os.sysconf('SC_CLK_TCK') / (now - before_time)
                        busy_since = (busy_since or now) if duty > .8 else None
                        if busy_since and now - busy_since > 1:
                            raise RuntimeError(f'PID {pid} sustained >80% CPU: ' + Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace'))
                    previous[pid] = (now, ticks, busy_since)
                for p, name in tuple(watched):
                    sample['processes'][name] = r.counters(p.pid)
                sample['gpu'] = {str(p): p.read_text().strip() for pattern in ('card*/device/gpu_busy_percent', 'card*/device/pp_dpm_sclk')
                                 for p in Path('/sys/class/drm').glob(pattern)}
                sample['cpu_frequency_khz'] = {cpu: Path(f'/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_cur_freq').read_text().strip()
                                               for cpu in result['cpus'].values()}
                sample['platform_profile'] = Path('/sys/firmware/acpi/platform_profile').read_text().strip()
                if sample['platform_profile'] != result['platform_profile']:
                    raise RuntimeError('power profile changed; measurement invalid')
                result['safety_samples'].append(sample)
            except Exception as error:
                result['safety_failure'] = str(error)
                os.kill(os.getpid(), signal.SIGTERM)
                return

    guard = threading.Thread(target=watchdog, daemon=True)

    def launch(command, environment, name, **kwargs):
        f = (args.output / name).open('w')
        logs.append(f)
        pin = (lambda: os.sched_setaffinity(0, {affinity[name]})) if name in affinity else None
        p = subprocess.Popen(command, env=environment, stdout=f, stderr=subprocess.STDOUT, preexec_fn=pin, start_new_session=True, **kwargs)
        processes.append(p)
        return p

    def enable_after_configure(process, instance, log):
        r.wait(lambda: re.search(r'xdg_surface[#@]\d+\.ack_configure\(', (args.output / log).read_text()), [process])
        before_ack = (args.output / log).read_text().split('.ack_configure(', 1)[0]
        if re.search(r'wl_surface[#@]\d+\.attach\(wl_buffer', before_ack):
            raise RuntimeError('buffer attached before initial configure acknowledgement')
        ctl = lambda command: r.ipc(instance, command)
        assert not ctl('configerrors').strip(), ctl('configerrors')
        assert ctl(f'eval hl.monitor({{output="WAYLAND-1",mode="{boot_w}x{boot_h}@{boot_hz}",scale={boot_scale},transform={boot_transform},reserved={{top={boot_top}}},disabled=false}})').strip() == 'ok'
        r.wait(lambda: any((m['width'], m['height'], m['transform']) == (boot_w, boot_h, boot_transform) and abs(m['scale'] - boot_scale) < 1e-5 and m['reserved'][1] == boot_top
                          for m in json.loads(ctl('j/monitors')) if m['name'] == 'WAYLAND-1'), [process])
        return ctl

    try:
        guard.start()
        parent = launch([str(args.weston), '--backend=headless', '--renderer=gl', f'--width={boot_w}', f'--height={boot_h}',
                         '--shell=kiosk-shell.so', f'--refresh-rate={boot_hz * 1000}', '--socket=parent', '--idle-time=0', '--no-config', '--fake-seat',
                         '--log=' + str(args.output / 'weston.log')], dict(env, EGL_PLATFORM='surfaceless'), 'parent.log')
        r.wait(lambda: (runtime / 'parent').exists(), [parent])
        bootstrap_config = args.output / 'bootstrap.kdl'
        bootstrap_config.write_text('animations { off; }\noutput "winit" { scale 1; }\nwindow-rule { match app-id="^aquamarine$"; open-fullscreen true; }\n')
        bootstrap = launch([str(args.bootstrap_niri), '--config', str(bootstrap_config)],
                           dict(env, WAYLAND_DISPLAY='parent', EGL_PLATFORM='wayland', RUST_LOG='info'), 'bootstrap.log')
        bootstrap_socket = r.wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), [bootstrap])
        watched.extend(((parent, 'weston'), (bootstrap, 'bootstrap')))
        bridge_instance = None
        if direct:
            niri_socket = r.wait(lambda: next(runtime.glob('niri.*.sock'), None), [bootstrap])
            def niri_outputs():
                outputs = json.loads(subprocess.check_output([str(args.bootstrap_niri), 'msg', '--json', 'outputs'],
                                     env=dict(env, NIRI_SOCKET=str(niri_socket)), text=True, timeout=2))
                return outputs if any(o['modes'][o['current_mode']]['width'] == boot_w and o['modes'][o['current_mode']]['height'] == boot_h
                                      for o in outputs.values() if o['current_mode'] is not None) else None
            result['parent_monitors'] = r.wait(niri_outputs, [bootstrap])
        else:
            bridge_listener.bind(str(runtime / 'bridge'))
            bridge_listener.listen(16)
            bridge = launch([str(args.parent_binary), '--socket', 'bridge', '--wayland-fd', str(bridge_listener.fileno()), '--config', str(wrapper)],
                            dict(env, WAYLAND_DISPLAY=bootstrap_socket, EGL_PLATFORM='wayland', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none', WAYLAND_DEBUG='client'),
                            'bridge.log', pass_fds=(bridge_listener.fileno(),))
            bridge_instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None), [bridge])
            bctl = enable_after_configure(bridge, bridge_instance, 'bridge.log')
            watched.append((bridge, 'bridge'))
            assert bctl('eval hl.monitor({output="HEADLESS-1",mode="800x1280@90",position="0x0",scale=1,transform=3})').strip() == 'ok'
            assert bctl('output create headless HEADLESS-1').strip() == 'ok'
            r.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(bctl('j/monitors'))), [bridge])
            assert bctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
            assert bctl(f'eval hl.window_rule({{name="nested",match={{class="^aquamarine$"}},float=true,size="{width} {height}",no_initial_focus=true,no_focus=true,render_unfocused=true}})').strip() == 'ok'
            result['parent_monitors'] = json.loads(bctl('j/monitors'))
        listener.bind(str(runtime / 'candidate'))
        listener.listen(16)
        child = launch([str(args.binary), '--socket', 'candidate', '--wayland-fd', str(listener.fileno()), '--config', str(wrapper)],
                       dict(env, WAYLAND_DISPLAY=bootstrap_socket if direct else 'bridge', EGL_PLATFORM='wayland', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none', WAYLAND_DEBUG='client',
                            **({'LD_PRELOAD': str(args.input_name_shim), 'CANVAS_TEST_POINTER_NAME': args.input_name} if args.input_name else {})),
                       'compositor.log', pass_fds=(listener.fileno(),))
        instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if p != bridge_instance and (p / '.socket.sock').exists()), None), [child])
        ctl = enable_after_configure(child, instance, 'compositor.log')
        if args.lens_condition:
            lens_value = args.lens_condition == 'on'
            assert ctl('eval hl.config({experimental={canvas_lens=' + json.dumps(lens_value) + '}})').strip() == 'ok'
            assert json.loads(ctl('j/getoption experimental:canvas_lens'))['bool'] == lens_value
            result['lens_condition'] = args.lens_condition
        watched.append((child, 'child'))
        if args.native_headless:
            assert ctl(f'eval hl.monitor({{output="HEADLESS-1",mode="{width}x{height}@{args.refresh}",scale={args.scale},transform={args.transform},reserved={{top={args.reserved_top}}},position="0x0"}})').strip() == 'ok'
            assert ctl('output create headless HEADLESS-1').strip() == 'ok'
            assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
            assert ctl('dispatch hl.dsp.focus({monitor="HEADLESS-1"})').strip() == 'ok'
            r.wait(lambda: [m['name'] for m in json.loads(ctl('j/monitors'))] == ['HEADLESS-1'], [child])
            actual = json.loads(ctl('j/monitors'))[0]
            assert (actual['width'], actual['height'], actual['transform'], actual['reserved'][1]) == (width, height, args.transform, args.reserved_top)
            assert abs(actual['scale'] - args.scale) < 1e-5 and abs(actual['refreshRate'] - args.refresh) < .1
        if args.other_output_damage:
            assert ctl('eval hl.monitor({output="HEADLESS-2",mode="1280x800@90",position="1280x0",scale=1})').strip() == 'ok'
            assert ctl('output create headless HEADLESS-2').strip() == 'ok'
            r.wait(lambda: len(json.loads(ctl('j/monitors'))) == 2, [child])
            assert ctl('dispatch hl.dsp.focus({monitor="WAYLAND-1"})').strip() == 'ok'
        result['renderer'] = re.findall(r'Renderer: (.*)', (instance / 'hyprland.log').read_text())
        assert result['renderer'] and not any(x in str(result['renderer']).lower() for x in ('llvmpipe', 'softpipe'))
        if args.pilot:
            result['monitors'] = json.loads(ctl('j/monitors'))
            assert [(m['width'], m['height'], m['transform']) for m in result['monitors'] if m['name'] == measured_output] == [(width, height, args.transform)]
            time.sleep(8)
            end = result['safety_samples'][-1]
            start = next(s for s in result['safety_samples'] if s['time'] >= end['time'] - 4 and 'child' in s['processes'])
            elapsed = end['time'] - start['time']
            assert elapsed >= 3, 'insufficient healthy pilot samples'
            assert all(end['cgroup_cpu'][k] == start['cgroup_cpu'][k] for k in ('nr_throttled', 'throttled_usec')), 'pilot CPU quota hit'
            assert start['gpu_clients'] and start['gpu_clients'].keys() == end['gpu_clients'].keys(), 'pilot GPU contexts unstable'
            cpu_duty = (end['cgroup_cpu']['usage_usec'] - start['cgroup_cpu']['usage_usec']) / (elapsed * 1e6)
            gpu_duty = sum(end['gpu_clients'][k]['gfx_ns'] - start['gpu_clients'][k]['gfx_ns'] for k in start['gpu_clients']) / (elapsed * 1e9)
            result['pilot_idle'] = {'seconds': elapsed, 'aggregate_cpu_cores': cpu_duty, 'aggregate_gfx_duty': gpu_duty}
            assert cpu_duty < .5 and gpu_duty < .25, 'pilot idle resource use too high'
            if args.native_headless:
                begin = time.monotonic() * 1000
                for delta in (32, -32):
                    assert ctl(f'dispatch hl.dsp.layout("pan {delta} 0")').strip() == 'ok'
                    time.sleep(.8)
                assert ctl('dispatch hl.dsp.layout("pan-end")').strip() == 'ok'
                stamps = [float(t) for t in re.findall(r'CZFRAME ([\d.]+)', (args.output / 'compositor.log').read_text()) if float(t) >= begin]
                gaps = [b - a for a, b in zip(stamps, stamps[1:])]
                assert len(gaps) >= 30 and .8 * 1000 / args.refresh <= statistics.median(gaps) <= 1.25 * 1000 / args.refresh, ('headless cadence mismatch', gaps)
                result['pilot_render_cadence'] = {'frames': len(stamps), 'p50_ms': statistics.median(gaps), 'max_ms': max(gaps)}
                image = args.output / 'pilot-full-resolution.png'
                subprocess.run(['grim', '-o', measured_output, str(image)], env=dict(env, WAYLAND_DISPLAY='candidate'), check=True, timeout=5)
                dimensions = subprocess.check_output(['magick', 'identify', '-format', '%w %h', str(image)], text=True, timeout=5)
                assert dimensions == f'{width} {height}', dimensions
            result['passed'] = True
            return
        appenv = dict(env, WAYLAND_DISPLAY='candidate', GDK_BACKEND='wayland')
        launch(['swaybg', '-c', '#374d68'], appenv, 'background.log')
        for n in range(args.clients):
            p = launch(['python3', str(ROOT / 'test-canvas-visuals.py'), '--client', str(args.output / f'app{n}'), str(n % 4)],
                       dict(appenv, **({'CANVAS_ZOOM_DAMAGE': args.damage or 'full'} if args.damage or args.cache_checks else {})), f'app{n}.log')
            r.wait(lambda: len(json.loads(ctl('j/clients'))) == n + 1, [child, p])
            time.sleep(.3)
        if args.two_rows:
            for window in reversed(json.loads(ctl('j/clients'))[-args.clients // 2:]):
                assert ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + window['address']) + '})').strip() == 'ok'
                assert ctl('dispatch hl.dsp.layout("move j")').strip() == 'ok'
                time.sleep(.3)
        time.sleep(16)
        result['monitors'] = json.loads(ctl('j/monitors'))
        assert [(m['width'], m['height'], m['transform']) for m in result['monitors'] if m['name'] == measured_output] == [(width, height, args.transform)]
        result['clients'] = json.loads(ctl('j/clients'))
        if args.other_output_damage:
            other = launch(['python3', str(ROOT / 'test-canvas-visuals.py'), '--client', str(args.output / 'other-app'), '0'],
                           dict(appenv, CANVAS_ZOOM_DAMAGE='full'), 'other-app.log')
            r.wait(lambda: len(json.loads(ctl('j/clients'))) == args.clients + 1, [child, other])
            other_address = next(w['address'] for w in json.loads(ctl('j/clients')) if w['pid'] == other.pid)
            assert ctl('dispatch hl.dsp.window.move({monitor="HEADLESS-2",window="address:' + other_address + '",follow=false})').strip() == 'ok'
            assert ctl('dispatch hl.dsp.focus({window="address:' + result['clients'][-1]['address'] + '"})').strip() == 'ok'
            time.sleep(2)
            other_marker = args.output / 'other-app/animate'
            other_marker.touch()
            result['other_client'] = other_address
            result['clients'] = [w for w in json.loads(ctl('j/clients')) if w['address'] != other_address]
        assert os.sched_getaffinity(child.pid) == {args.cpu}
        if not direct:
            assert os.sched_getaffinity(bridge.pid) == {args.parent_cpu}
        assert os.sched_getaffinity(bootstrap.pid) == {affinity['bootstrap.log']}
        assert os.sched_getaffinity(parent.pid) == {args.weston_cpu}
        result['options'] = {key: json.loads(ctl('j/getoption experimental:' + key)) for key in
                             ('canvas_lens', 'canvas_lens_strength', 'canvas_lens_edge_scale', 'canvas_vignette',
                              'canvas_backdrop_blur', 'canvas_parallax_strength', 'canvas_parallax_depth')}
        text = (args.output / 'compositor.log').read_text()
        surface = re.search(r'get_xdg_surface\([^\n]*wl_surface[#@](\d+)\)', text)[1]

        def dispatch(command):
            result.setdefault('dispatches', []).append({'time': time.monotonic(), 'wall_time': time.time(), 'command': command, 'child_counters': r.counters(child.pid)})
            answer = ctl('dispatch hl.dsp.layout(' + json.dumps(command) + ')').strip()
            assert answer == 'ok', answer

        def shot(name):
            path = args.output / (name + '.png')
            subprocess.run(['grim', '-l', '0', '-o', measured_output, str(path)], env=appenv, check=True, timeout=10)
            result['captures'][name] = r.sha(path)

        if args.other_output_damage:
            def shot_b(name):
                path = args.output / (name + '.png')
                subprocess.run(['grim', '-o', 'HEADLESS-2', str(path)], env=appenv, check=True, timeout=5)
                result['captures'][name] = r.sha(path)
            shot_b('B-first')
            for _ in range(10):
                time.sleep(.05)
                shot_b('B-changing')
                if result['captures']['B-changing'] != result['captures']['B-first']:
                    break
            assert result['captures']['B-changing'] != result['captures']['B-first'], 'B did not produce live damage'

        def body_bounds(name):
            logical_width, logical_height = (height, width) if args.transform == 3 else (width, height)
            row = subprocess.check_output(['magick', str(args.output / (name + '.png')), '-crop',
                                           f'{logical_width}x1+0+{logical_height // 2}', '+repage', '-depth', '8', 'rgb:-'], timeout=5)
            assert len(row) == logical_width * 3
            center = row[logical_width // 2 * 3:logical_width // 2 * 3 + 3]
            left = right = logical_width // 2
            matches = lambda x: max(abs(a - b) for a, b in zip(row[x * 3:x * 3 + 3], center)) < 8
            while left > 0 and matches(left - 1):
                left -= 1
            while right < logical_width - 1 and matches(right + 1):
                right += 1
            return left, right, list(center)

        def layout():
            return {w['address']: (w['at'], w['size'], w['floating'], w['workspace']['name']) for w in json.loads(ctl('j/clients'))}

        def cycles(count, phase=None):
            for _ in range(count):
                dispatch('overview')
                time.sleep(1.4)
                if phase:
                    nearest = json.loads(ctl('j/monitors'))[0]['canvasNearest']
                    assert nearest in initial_layout and layout() == initial_layout, 'overview lost a client or changed native layout'
                    shot(phase + '-overview')
                    left, right, color = body_bounds(phase + '-overview')
                    assert max(abs(a - b) for a, b in zip(color, normal_bounds[2])) < 10, 'focused client content disappeared'
                    ratio = (right - left + 1) / (normal_bounds[1] - normal_bounds[0] + 1)
                    lens = json.loads(ctl('j/getoption experimental:canvas_lens'))['bool']
                    if lens:
                        radius2 = ((right - left + 1) / logical_width) ** 2
                        ratio *= (1 + result['options']['canvas_lens_strength']['float'] * radius2) / result['options']['canvas_lens_edge_scale']['float']
                    assert abs(ratio - expected_zoom) < .03 and ratio < .999, ('native zoom not visible', ratio, expected_zoom)
                    result.setdefault('phase_checks', {})[phase] = {'nearest': nearest, 'clients': len(initial_layout),
                                                                  'expected_zoom': expected_zoom, 'image_inferred_zoom': ratio,
                                                                  'focused_body_bounds': [left, right]}
                if args.motion == 'pan':
                    for direction in (-1, 1):
                        for _ in range(8):
                            dispatch(f'pan {direction * 160} 0')
                            time.sleep(.1)
                    time.sleep(.6)
                dispatch('overview')
                time.sleep(1.4)
                if phase:
                    assert not json.loads(ctl('j/monitors'))[0]['canvasNearest'], 'overview did not complete its return'
                    assert layout() == initial_layout, 'return changed native layout or clients'
                    shot(phase + '-returned')
                    assert result['captures'][phase + '-returned'] == result['captures']['normal'], 'diagnostic did not restore normal view'

        def animate(active):
            if args.damage:
                for n in range(args.clients):
                    marker = args.output / f'app{n}' / 'animate'
                    marker.touch() if active else marker.unlink()
                time.sleep(.3)

        if args.input_name:
            input_path = ROOT / 'canvas_deck_input_test.py'
            input_spec = importlib.util.spec_from_file_location('deck_input', input_path)
            input_test = importlib.util.module_from_spec(input_spec)
            input_spec.loader.exec_module(input_test)
            result['input_fixture'] = {str(p): r.sha(p) for p in (input_path, args.input_name_shim, args.input_keys)}
            result['controller_input'] = input_test.run(ctl, bctl, runtime, appenv, args.input_keys, args.output, args.input_name)
        shot('normal')
        if args.screen:
            normal_bounds = body_bounds('normal')
            original_animations = json.loads(ctl('j/getoption animations:enabled'))['bool']
            assert original_animations, 'timing must use the canonical animated transition'
            initial_layout = layout()
            assert len(initial_layout) == args.clients
            logical_width, logical_height = (height, width) if args.transform == 3 else (width, height)
            reserved = result['monitors'][0]['reserved']
            boxes = result['clients']
            span_x = max(w['at'][0] + w['size'][0] for w in boxes) - min(w['at'][0] for w in boxes)
            span_y = max(w['at'][1] + w['size'][1] for w in boxes) - min(w['at'][1] for w in boxes)
            expected_zoom = max(.25, min(1, (logical_width / args.scale - reserved[0] - reserved[2]) / (span_x + 96),
                                        (logical_height / args.scale - reserved[1] - reserved[3]) / (span_y + 96)))
            result['ablation_scope'] = ('unchanged baseline control' if args.screen == 'control' else
                                        'whole radial-lens rendering and hit-test projection; native camera retained' if args.screen == 'canvas_lens' else 'backdrop-only effect')
        dispatch('overview')
        time.sleep(2)
        shot('overview')
        dispatch('pan 180 0')
        time.sleep(1)
        shot('panned')
        dispatch('pan -180 0')
        time.sleep(1)
        dispatch('overview')
        time.sleep(2)
        animate(True)
        if args.damage:
            dispatch('overview')
            time.sleep(1.4)
            first = args.output / 'updating-first.png'
            second = args.output / 'updating-second.png'
            subprocess.run(['grim', '-o', 'WAYLAND-1', str(first)], env=appenv, check=True, timeout=10)
            for _ in range(10):
                time.sleep(.05)
                subprocess.run(['grim', '-o', 'WAYLAND-1', str(second)], env=appenv, check=True, timeout=10)
                if r.sha(first) != r.sha(second):
                    break
            assert r.sha(first) != r.sha(second), 'animated clients did not update in overview'
            result['animated_updates_visible'] = True
            dispatch('overview')
            time.sleep(1.4)
        cycles(3)
        original = result['options'][args.screen] if args.screen and args.screen != 'control' else None
        original_value = original.get('bool', original.get('float')) if original else None
        phases = [('baseline-before', original_value), ('diagnostic-only', False if isinstance(original_value, bool) else 0),
                  ('baseline-after', original_value)] if args.screen else [('baseline', None)] * args.repeats
        if args.screen == 'control':
            phases = [('baseline-before', None)] if args.lens_condition else [('baseline-before', None), ('baseline-after', None)]
        for repeat, (phase, value) in enumerate([] if args.cache_checks else phases):
            if args.screen:
                if args.screen != 'control':
                    assert ctl('eval hl.config({experimental={' + args.screen + '=' + json.dumps(value) + '}})').strip() == 'ok'
                cycles(1, phase=phase)
                assert ctl('eval hl.config({animations={enabled=false}})').strip() == 'ok'
                capture_start = time.monotonic()
                dispatch('overview')
                time.sleep(.35)
                shot(phase + '-canonical-overview')
                result.setdefault('canonical_states', {})[phase] = {
                    'start': capture_start, 'end': time.monotonic(), 'monitors': json.loads(ctl('j/monitors')),
                    'focus': json.loads(ctl('j/activewindow')),
                    'options': {key: json.loads(ctl('j/getoption experimental:' + key)) for key in result['options']}}
                if args.screen == 'control':
                    assert result['canonical_states'][phase]['options'] == result['options'], 'control changed visual options'
                dispatch('overview')
                time.sleep(.35)
                assert ctl('eval hl.config({animations={enabled=true}})').strip() == 'ok'
                cycles(1)
            path = args.output / 'compositor.log'
            offset = path.stat().st_size
            all_before = {name: r.counters(p.pid) for p, name in watched}
            gpu_before = gpu_clients()
            cgroup_before = cpu_stat()
            before = all_before['child']
            measuring.set()
            cycles(args.cycles)
            all_after = {name: r.counters(p.pid) for p, name in watched}
            cgroup_after = cpu_stat()
            gpu_after = gpu_clients()
            measuring.clear()
            assert all(cgroup_after[k] == cgroup_before[k] for k in ('nr_throttled', 'throttled_usec')), 'CPU quota hit; invalid measurement'
            assert gpu_before and gpu_before.keys() == gpu_after.keys(), 'GPU clients changed during timing; invalid measurement'
            after = all_after['child']
            with path.open() as f:
                f.seek(offset)
                tail = f.read()
            native_stamps = [float(t) for t in re.findall(r'CZFRAME ([\d.]+)', tail) if before['time'] * 1000 <= float(t) <= after['time'] * 1000]
            frames = len(native_stamps) if args.native_headless else len(re.findall(r'-> wl_surface[#@]' + surface + r'\.commit\(', tail))
            assert frames > args.cycles * 20, frames
            row = {'repeat': repeat, 'phase': phase, 'diagnostic_only': bool(args.screen), 'transitions': args.cycles * 2,
                   'frames': frames, 'start': before['time'], 'end': after['time'], 'seconds': after['time'] - before['time'],
                   'aggregate_cpu_ms': (cgroup_after['usage_usec'] - cgroup_before['usage_usec']) / 1000,
                   'aggregate_gpu_ms': sum(gpu_after[k]['gfx_ns'] - gpu_before[k]['gfx_ns'] for k in gpu_before) / 1e6,
                   'cgroup_before': cgroup_before, 'cgroup_after': cgroup_after, 'gpu_before': gpu_before, 'gpu_after': gpu_after,
                   'process_totals': {name: {'gpu_ms': (all_after[name]['gfx_ns'] - counter['gfx_ns']) / 1e6,
                                             'cpu_ms': (all_after[name]['cpu_ticks'] - counter['cpu_ticks']) * 1000 / os.sysconf('SC_CLK_TCK')}
                                      for name, counter in all_before.items()},
                   'render_tail_ms': None,
                   'cpu_ms': (after['cpu_ticks'] - before['cpu_ticks']) * 1000 / os.sysconf('SC_CLK_TCK'),
                   'gpu_ms': (after['gfx_ns'] - before['gfx_ns']) / 1e6}
            stamps = re.findall(r'\[(\d+):(\d+):([\d.]+)\][^\n]*-> wl_surface[#@]' + surface + r'\.commit\(', tail)
            commits = native_stamps if args.native_headless else [(int(h) * 3600 + int(m) * 60 + float(s)) * 1000 for h, m, s in stamps]
            intervals = sorted(b - a for a, b in zip(commits, commits[1:]))
            assert intervals, 'missing commit timestamps'
            assert row['cpu_ms'] > 0 and row['gpu_ms'] > 0, 'transition rendering work vanished'
            row.update(cpu_ms_per_transition=row['cpu_ms'] / row['transitions'], gpu_ms_per_transition=row['gpu_ms'] / row['transitions'],
                       cpu_ms_per_frame=row['cpu_ms'] / frames, gpu_ms_per_frame=row['gpu_ms'] / frames,
                       commit_interval_p50_ms=statistics.median(intervals), commit_interval_p95_ms=intervals[int(len(intervals) * .95)],
                       commit_interval_p99_ms=intervals[int(len(intervals) * .99)], commit_interval_max_ms=max(intervals),
                       commits_over_25ms=sum(x > 25 for x in intervals))
            render_times = sorted(float(duration) for stamp, duration in re.findall(r'CZFRAME ([\d.]+) ([\d.]+)', tail)
                                  if before['time'] * 1000 <= float(stamp) <= after['time'] * 1000)
            if render_times:
                row['render_tail_ms'] = {'samples': len(render_times), 'p50': statistics.median(render_times),
                                         'p95': render_times[int(len(render_times) * .95)], 'p99': render_times[int(len(render_times) * .99)],
                                         'max': max(render_times)}
            if args.native_headless:
                row = {k.replace('commit_interval_', 'render_interval_').replace('commits_over_', 'render_gaps_over_'): v for k, v in row.items()}
            result['trials'].append(row)
            print(json.dumps(row), flush=True)
        result['memory_high_water_kb'] = int(re.search(r'VmHWM:\s*(\d+)', Path(f'/proc/{child.pid}/status').read_text())[1])
        animate(False)
        time.sleep(1)
        shot('returned')
        assert result['captures']['returned'] == result['captures']['normal'], 'zoom round-trip changed the settled frame'
        assert result['captures']['overview'] != result['captures']['normal']
        assert result['captures']['panned'] != result['captures']['overview']
        if args.screen:
            if args.screen != 'control':
                restored = json.loads(ctl('j/getoption experimental:' + args.screen))
                assert restored.get('bool', restored.get('float')) == original_value
            if not args.lens_condition:
                assert result['captures']['baseline-before-canonical-overview'] == result['captures']['baseline-after-canonical-overview'], 'canonical overview image was not restored'
            else:
                assert json.loads(ctl('j/getoption experimental:canvas_lens'))['bool'] == (args.lens_condition == 'on')
            assert json.loads(ctl('j/getoption animations:enabled'))['bool'] == original_animations
        if args.cache_checks:
            other_marker.unlink()
            focus = lambda name: ctl('dispatch hl.dsp.focus({monitor=' + json.dumps(name) + '})').strip()
            focus('HEADLESS-2'); dispatch('overview'); time.sleep(1.4)
            shot_b('B-overview')
            focus('WAYLAND-1'); dispatch('overview'); time.sleep(1.4)
            dispatch('pan -4096 0'); time.sleep(1.4)
            dispatch('pan 4096 0'); time.sleep(1.4)
            dispatch('overview'); time.sleep(1.4)
            shot_b('B-after-A-return')
            assert result['captures']['B-overview'] == result['captures']['B-after-A-return'], 'A return changed B overview'
            moved = result['clients'][0]['address']
            for output in ('HEADLESS-2', 'WAYLAND-1'):
                assert ctl('dispatch hl.dsp.window.move({monitor=' + json.dumps(output) + ',window="address:' + moved + '",follow=false})').strip() == 'ok'
                time.sleep(1.4)
            for scale, transform in ((1.25, 1), (1, 0)):
                assert ctl(f'eval hl.monitor({{output="HEADLESS-2",mode="1280x800@90",position="1280x0",scale={scale},transform={transform}}})').strip() == 'ok'
                time.sleep(1.4)
            closing = next(p for p in processes if p.pid == result['clients'][-1]['pid'])
            expected_exits.add(closing); closing.terminate(); closing.wait(timeout=5)
            assert ctl('output remove HEADLESS-2').strip() == 'ok'
            assert ctl('output create headless HEADLESS-2').strip() == 'ok'
            r.wait(lambda: len(json.loads(ctl('j/monitors'))) == 2, [child])
            assert ctl('dispatch hl.dsp.window.move({monitor="HEADLESS-2",window="address:' + other_address + '",follow=false})').strip() == 'ok'
            assert ctl('dispatch hl.dsp.focus({window="address:' + moved + '"})').strip() == 'ok'
            time.sleep(2); shot('before-shader')
            shader_dir = args.output / 'shader-override'; shader_dir.mkdir()
            (shader_dir / 'surface.frag').write_text('#version 300 es\nprecision highp float;\nin vec2 v_texcoord;\nuniform sampler2D tex;\nuniform float alpha;\nout vec4 fragColor;\nvoid main(){fragColor=texture(tex,v_texcoord)*alpha*0.5;}\n')
            assert ctl('reloadshaders ' + str(shader_dir)).strip() == 'ok'
            time.sleep(.5); shot('shader-override')
            assert result['captures']['shader-override'] != result['captures']['before-shader']
            assert ctl('reloadshaders').strip() == 'ok'
            time.sleep(.5); shot('shader-restored')
            assert result['captures']['shader-restored'] == result['captures']['before-shader']
            dispatch('overview'); time.sleep(1.4)
            lock = launch(['swaylock', '--config', '/dev/null', '--color', '00000000', '--no-unlock-indicator'], dict(appenv, WAYLAND_DEBUG='client'), 'lock.log')
            r.wait(lambda: '.locked(' in (args.output / 'lock.log').read_text(), [child, lock])
            time.sleep(1.4)
            def locked_shot(name):
                path = args.output / (name + '.png')
                subprocess.run([str(args.bootstrap_niri), 'msg', 'action', 'screenshot-screen', '--path', str(path), '--show-pointer', 'false'],
                               env=dict(env, NIRI_SOCKET=str(niri_socket)), check=True, timeout=5, stdout=subprocess.DEVNULL)
                r.wait(lambda: path.exists() and path.stat().st_size > 0, [child])
                result['captures'][name] = r.sha(path)
            locked_shot('locked-before-pan')
            dispatch('pan -4096 0'); time.sleep(1.4)
            (args.output / 'app0/animate').touch()
            dispatch('pan 4096 0'); time.sleep(1.4)
            locked_shot('locked-after-pan')
            assert result['captures']['locked-before-pan'] == result['captures']['locked-after-pan'], 'locked pan lost frozen output'
            expected_exits.add(lock); lock.send_signal(signal.SIGUSR1); lock.wait(timeout=5)
            time.sleep(2); shot('thawed-first')
            for _ in range(10):
                time.sleep(.05); shot('thawed-second')
                if result['captures']['thawed-first'] != result['captures']['thawed-second']:
                    break
            assert result['captures']['thawed-first'] != result['captures']['thawed-second'], 'unlock did not restore live updates'
            (args.output / 'app0/animate').unlink()
            result['cache_lifecycle_checks'] = True
        if direct:
            result['passed'] = True
            return
        assert ctl('eval hl.config({animations={enabled=false}})').strip() == 'ok'
        dispatch('overview')
        time.sleep(1)
        shot('static-overview')
        dispatch('pan 180 0')
        time.sleep(.3)
        shot('static-panned')
        dispatch('pan -180 0')
        time.sleep(.3)
        assert ctl('eval hl.window_rule({name="alpha",match={title="^Browser"},opacity="0.55"})').strip() == 'ok'
        time.sleep(1)
        shot('translucent')
        assert ctl('eval hl.config({experimental={canvas_chromatic=0.2,canvas_edge_blur=0.15,canvas_lens_feather=0.02}})').strip() == 'ok'
        time.sleep(1)
        shot('lens-options')
        assert ctl('eval hl.config({experimental={canvas_chromatic=0,canvas_edge_blur=0,canvas_lens_feather=0}})').strip() == 'ok'
        time.sleep(1)
        if args.lifecycle:
            pixels = subprocess.check_output(['magick', str(args.output / 'static-overview.png'), '-format',
                                               '%[fx:p{640,400}.r] %[fx:p{640,400}.g] %[fx:p{640,400}.b]', 'info:'], text=True)
            result['focused_tile_rgb'] = list(map(float, pixels.split()))
            assert max(result['focused_tile_rgb']) < .15, 'focused overview tile contains wallpaper instead of client content'
            nearest = json.loads(ctl('j/monitors'))[0]['canvasNearest']
            closing = next(w for w in json.loads(ctl('j/clients')) if w['address'] == nearest)
            proc = next(p for p in processes if p.pid == closing['pid'])
            expected_exits.add(proc)
            proc.terminate()
            proc.wait(timeout=10)
            r.wait(lambda: len(json.loads(ctl('j/clients'))) == args.clients - 1, [child])
            dispatch('pan 80 0')
            dispatch('pan -80 0')
            time.sleep(.5)
            assert json.loads(ctl('j/monitors'))[0]['canvasNearest'] != nearest
            result['closed_overview_client'] = True
            assert ctl('eval hl.monitor({output="HEADLESS-2",mode="1280x800@60",position="1280x0",scale=1})').strip() == 'ok'
            assert ctl('output create headless HEADLESS-2').strip() == 'ok'
            r.wait(lambda: len(json.loads(ctl('j/monitors'))) == 2, [child])
            moved = json.loads(ctl('j/clients'))[0]['address']
            assert ctl('dispatch hl.dsp.window.move({monitor="HEADLESS-2",window=' + json.dumps('address:' + moved) + ',follow=false})').strip() == 'ok'
            assert ctl('dispatch hl.dsp.focus({monitor="HEADLESS-2"})').strip() == 'ok'
            dispatch('overview')
            time.sleep(1)
            assert next(m for m in json.loads(ctl('j/monitors')) if m['name'] == 'HEADLESS-2')['canvasNearest'] == moved
            subprocess.run(['grim', '-o', 'HEADLESS-2', str(args.output / 'second-output.png')], env=appenv, check=True, timeout=10)
            assert ctl('dispatch hl.dsp.focus({monitor="WAYLAND-1"})').strip() == 'ok'
            result['second_output_overview'] = True
        lock = launch(['swaylock', '--config', '/dev/null', '--color', '00000000'] + (['--no-unlock-indicator'] if args.input_name else []),
                      dict(appenv, WAYLAND_DEBUG='client'), 'lock.log')
        r.wait(lambda: 'ext_session_lock_v1' in (args.output / 'lock.log').read_text() and '.locked(' in (args.output / 'lock.log').read_text(), [child, lock])
        time.sleep(2)
        locked = args.output / 'locked.png'
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(locked)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
        result['captures']['locked'] = r.sha(locked)
        if args.input_name:
            result['controller_locked'] = input_test.run(ctl, bctl, runtime, appenv, args.input_keys, args.output, args.input_name, locked=True)
            held_lock = args.output / 'locked-controller-input.png'
            subprocess.run(['grim', '-o', 'HEADLESS-1', str(held_lock)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
            assert r.sha(held_lock) == r.sha(locked), 'controller input changed locked output'
        if args.damage:
            animate(True)
            time.sleep(1)
            frozen = args.output / 'locked-live-damage.png'
            subprocess.run(['grim', '-o', 'HEADLESS-1', str(frozen)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
            result['captures']['locked-live-damage'] = r.sha(frozen)
            assert r.sha(locked) == r.sha(frozen), 'client updates changed frozen locked output'
        before_late = len(json.loads(ctl('j/clients')))
        late = launch(['python3', str(ROOT / 'test-canvas-visuals.py'), '--client', str(args.output / 'late'), '0'], appenv, 'late.log')
        r.wait(lambda: len(json.loads(ctl('j/clients'))) == before_late + 1, [child, late])
        time.sleep(1)
        hidden = args.output / 'locked-late-client.png'
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(hidden)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
        result['captures']['locked-late-client'] = r.sha(hidden)
        assert result['captures']['locked'] == result['captures']['locked-late-client'], 'late client changed locked output'
        if args.lifecycle:
            expected_exits.add(lock)
            lock.terminate()
            lock.wait(timeout=10)
            time.sleep(5)
            missing = args.output / 'missing-lock.png'
            subprocess.run(['grim', '-o', 'HEADLESS-1', str(missing)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
            assert r.sha(missing) != r.sha(locked), 'missing lock surface did not change the secure fallback'
            result['missing_lock_fallback'] = True
        result['passed'] = True
    except BaseException as error:
        result['failure'] = {'type': type(error).__name__, 'message': str(error), 'traceback': traceback.format_exc()}
        raise
    finally:
        stopping.set()
        guard.join(timeout=1)
        for path in list(args.output.glob('*.log')) + list((runtime / 'hypr').glob('*/hyprland.log')):
            if match := fatal.search(path.read_text(errors='replace')):
                result['safety_failure'] = f'{path.name}: {match[0]}'
        result['cleanup_started'] = time.monotonic()
        result['cleanup_offsets'] = {str(p): p.stat().st_size for p in list(args.output.glob('*.log')) + list((runtime / 'hypr').glob('*/hyprland.log'))}
        for p in reversed(processes):
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                result.setdefault('cleanup_errors', []).append(p.args)
            finally:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait()
        listener.close()
        bridge_listener.close()
        for log in logs:
            log.close()
        for log in (runtime / 'hypr').glob('*/hyprland.log'):
            shutil.copyfile(log, args.output / ('runtime-' + log.parent.name + '.log'))
        shutil.rmtree(runtime)
        result['passed'] = result['passed'] and not result.get('cleanup_errors') and not result.get('safety_failure')
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        if result.get('cleanup_errors') or result.get('safety_failure'):
            raise RuntimeError(result.get('safety_failure', result.get('cleanup_errors')))
    assert result['passed'], result.get('cleanup_errors')


if __name__ == '__main__':
    main()
