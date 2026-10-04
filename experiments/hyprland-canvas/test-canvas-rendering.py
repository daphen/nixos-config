#!/usr/bin/env python3
"""Baseline/candidate checks through canvas IPC, real GTK buffers and screencopy."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / 'dotfiles/hyprland/.config/hypr/hyprland.lua'
CLIENT = Path(__file__).parent / 'regression-archive/hyprland-canvas-resize/client.py'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ipc(instance, command):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5)
        sock.connect(str(instance / '.socket.sock'))
        sock.sendall(command.encode())
        data = b''
        while chunk := sock.recv(65536):
            data += chunk
    return data.decode()


def wait(predicate, processes):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        assert all(p.poll() is None for p in processes), 'test process exited; inspect logs'
        time.sleep(.05)
    raise TimeoutError('test condition not reached; inspect logs')


def counters(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    seen, gfx = set(), 0
    for path in Path(f'/proc/{pid}/fdinfo').iterdir():
        try:
            text = path.read_text()
        except FileNotFoundError:
            continue
        identity = re.search(r'drm-client-id:\s*(\d+)', text)
        engine = re.search(r'drm-engine-gfx:\s*(\d+)', text)
        device = re.search(r'drm-pdev:\s*(\S+)', text)
        key = (device[1] if device else '', identity[1] if identity else '')
        if identity and engine and key not in seen:
            seen.add(key)
            gfx += int(engine[1])
    assert seen, 'no readable DRM graphics-engine counters; do not report zero GPU cost'
    return {'time': time.monotonic(), 'gfx_ns': gfx, 'cpu_ticks': int(fields[11]) + int(fields[12])}


def main():
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--scale', type=float, choices=(1, 1.5, 1.6666666), default=1)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--size', type=int, nargs=2, default=(1296, 720), metavar=('WIDTH', 'HEIGHT'))
    parser.add_argument('--visible', action='store_true', help='map on the parent desktop; requires user approval for physical outputs')
    parser.add_argument('--headless', action='store_true', help='test a private headless output; never show the bootstrap window')
    parser.add_argument('--pan-only', action='store_true', help='panning cost and settled screenshots only; omit damage recordings')
    parser.add_argument('--wallpaper', type=Path, help='opaque image rendered by a real layer-shell background client')
    parser.add_argument('--log-damage', action='store_true', help='count native full-monitor invalidations; timing includes logging')
    parser.add_argument('--reference', type=Path, help='passed run with identical fixtures/config/scale; compare settled pixels')
    parser.add_argument('--input-replay', type=Path, help='recorded layout commands with monotonic offsets; use a two-row fixture')
    args = parser.parse_args()
    assert args.repeats >= 1
    width, height = args.size
    assert width > 0 and height > 0
    assert not (args.headless and args.visible)
    assert not args.headless or args.pan_only
    replay = None
    if args.input_replay:
        args.input_replay = args.input_replay.resolve(strict=True)
        replay = json.loads(args.input_replay.read_text())['events']
        assert args.pan_only and args.repeats == 1 and replay
        assert all(e['t'] >= 0 and (re.fullmatch(r'focus [hjkl]', e['command']) or e['command'] in ('pan-begin', 'pan-end', 'pan-overview') or e['command'].startswith('pan ')) for e in replay)
        assert all(a['t'] <= b['t'] for a, b in zip(replay, replay[1:]))
    args.binary = args.binary.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    runtime = Path(tempfile.mkdtemp(prefix='ct-'))
    parent_pid, parent_display = (args.parent_instance / 'hyprland.lock').read_text().splitlines()
    assert Path(f'/proc/{parent_pid}').exists(), 'parent lock is stale'
    parent = lambda cmd: ipc(args.parent_instance, cmd)
    rule = f'canvas_render_test_{os.getpid()}'
    workspace = json.loads(parent('j/activeworkspace'))['address'] if args.visible else 'special:' + rule
    env = os.environ.copy()
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NIRI_SOCKET', 'SWAYSOCK', 'NOTIFY_SOCKET'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(args.output / 'state'),
               XDG_CONFIG_HOME=str(args.output / 'config'), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation')
    wrapper = args.output / 'hyprland.lua'
    wrapper.write_text('local on=hl.on\nhl.on=function(event,cb) if event~="hyprland.start" then return on(event,cb) end end\n'
                       + 'dofile(' + json.dumps(str(CONFIG)) + ')\nhl.on=on\nhl.config({misc={disable_splash_rendering=true}})\n'
                       + ('hl.config({debug={log_damage=true,enable_stdout_logs=true,disable_logs=false}})\n' if args.log_damage else '')
                       + f'hl.monitor({{output="WAYLAND-1",mode="{width}x{height}@120",scale={args.scale}}})\n')
    (args.output / 'canvas-state.lua').write_bytes(CONFIG.with_name('canvas-state.lua').read_bytes())
    hashes = {str(p): sha(p) for p in (args.binary, CONFIG, CLIENT, Path(__file__), wrapper,
              CONFIG.with_name('canvas-state.lua'), Path(__file__).with_name('whole-canvas-camera.patch'))}
    if args.input_replay:
        hashes[str(args.input_replay)] = sha(args.input_replay)
    if args.wallpaper:
        args.wallpaper = args.wallpaper.resolve(strict=True)
        hashes[str(args.wallpaper)] = sha(args.wallpaper)
    result = {'visible': args.visible, 'headless': args.headless, 'pan_only': args.pan_only, 'hashes': hashes, 'git_head': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
              'measurement': 'nested compositor; GPU busy time per submitted commit is NOT physical presentation/FPS',
              'parent_pid': int(parent_pid), 'parent_binary_sha256': sha(f'/proc/{parent_pid}/exe'),
              'scale': args.scale, 'repeats': args.repeats, 'log_damage': args.log_damage, 'trials': [], 'visual': [], 'passed': False,
              'parent_monitors': json.loads(parent('j/monitors')),
              'platform_profile': Path('/sys/firmware/acpi/platform_profile').read_text().strip(),
              'capture_tools': {name: subprocess.check_output([name, '-version' if 'ffmpeg' in name else '--version'], text=True, stderr=subprocess.STDOUT).splitlines()[0]
                                for name in (args.ffmpeg, 'wf-recorder')}}
    if args.reference:
        reference = json.loads((args.reference / 'result.json').read_text())
        assert reference['passed'] and reference['scale'] == args.scale and reference['repeats'] == args.repeats
        assert reference['log_damage'] == args.log_damage, 'reference logging differs'
        assert reference.get('visible', False) == args.visible and reference.get('pan_only', False) == args.pan_only
        assert reference.get('headless', False) == args.headless
        if args.input_replay:
            assert reference['hashes'].get(str(args.input_replay)) == hashes[str(args.input_replay)]
        if args.wallpaper:
            assert reference['hashes'].get(str(args.wallpaper)) == hashes[str(args.wallpaper)]
        for path in (CONFIG, CLIENT, Path(__file__), CONFIG.with_name('canvas-state.lua')):
            assert reference['hashes'][str(path)] == hashes[str(path)], 'reference test inputs differ'
    processes, logs, folders = [], [], []
    listener, rule_added = None, False

    def launch(command, environment, name, **kwargs):
        log = (args.output / name).open('w')
        logs.append(log)
        proc = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        processes.append(proc)
        return proc

    def stop(proc, sig=signal.SIGTERM):
        if proc.poll() is None:
            proc.send_signal(sig)
            if proc.args[0] == 'wf-recorder' and sig == signal.SIGTERM:
                for folder in folders:
                    marker = folder / 'patch-state'
                    marker.write_text(str(int(marker.read_text()) + 1))
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                raise RuntimeError('test process required SIGKILL')

    try:
        assert parent('eval ' + rule + '=hl.window_rule({name=' + json.dumps(rule)
                      + ',match={class="^aquamarine$"},workspace=' + json.dumps(workspace + ' silent')
                      + f',float=true,size="{width} {height}",no_initial_focus=true,no_focus=true,render_unfocused=true}})').strip() == 'ok'
        rule_added = True
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / 'canvas-test'))
        listener.listen(16)
        child_env = dict(env, WAYLAND_DISPLAY=str(args.parent_instance.parent.parent / parent_display),
                         AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none', WAYLAND_DEBUG='client')
        child = launch([str(args.binary), '--socket', 'canvas-test', '--wayland-fd', str(listener.fileno()),
                        '--config', str(wrapper)], child_env, 'compositor.log', pass_fds=(listener.fileno(),))
        instance = wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None), [child])
        ctl = lambda cmd: ipc(instance, cmd)
        if not args.headless:
            outer = wait(lambda: next((w for w in json.loads(parent('j/clients')) if w['pid'] == child.pid), None), [child])
            assert outer['floating'] and outer['workspace']['address'] == workspace, outer
        assert json.loads(parent('j/activewindow')).get('pid') != child.pid, 'fixture stole focus'
        assert not ctl('configerrors').strip(), ctl('configerrors')
        if args.headless:
            assert ctl(f'eval hl.monitor({{output="HEADLESS-1",mode="{width}x{height}@120",scale={args.scale}}})').strip() == 'ok'
            assert ctl('output create headless HEADLESS-1').strip() == 'ok'
            wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [child])
            assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
            wait(lambda: all(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [child])
        appenv = dict(env, WAYLAND_DISPLAY='canvas-test', GDK_BACKEND='wayland', WAYLAND_DEBUG='client')
        if args.wallpaper:
            launch(['swaybg', '-i', str(args.wallpaper), '-m', 'fill'], appenv, 'wallpaper.log')
            time.sleep(.5)
        for n in range(4):
            folder = args.output / f'app{n}'
            folder.mkdir()
            folders.append(folder)
            launch(['python3', str(CLIENT), str(folder)], dict(appenv, CANVAS_PARTIAL_DAMAGE='1'), f'app{n}.log')
            wait(lambda: len(json.loads(ctl('j/clients'))) == n + 1 and (folder / 'patch-drawn').exists(), [child, processes[-1]])
            time.sleep(.2)
        if replay:
            clients = json.loads(ctl('j/clients'))
            for window in reversed(clients[-2:]):
                assert ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + window['address']) + '})').strip() == 'ok'
                assert ctl('dispatch hl.dsp.layout("move j")').strip() == 'ok'
                time.sleep(.5)
            assert ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + clients[0]['address']) + '})').strip() == 'ok'
        # Native startup notices last 15 seconds and otherwise contaminate frames and screenshots.
        time.sleep(16)
        if replay:
            result['replay_initial_clients'] = json.loads(ctl('j/clients'))
            assert len({round(w['at'][1]) for w in result['replay_initial_clients']}) == 2, 'replay fixture must have two rows'
        result['monitors'] = json.loads(ctl('j/monitors'))
        monitor = result['monitors'][0]
        assert (monitor['width'], monitor['height'], monitor['scale']) == (width, height, args.scale), monitor
        pixels = monitor['width'] * monitor['height']
        source = (args.output / 'compositor.log').read_text()
        surface = re.search(r'get_xdg_surface\([^\n]*wl_surface[#@](\d+)\)', source)[1]
        sequence = 0

        def dispatch(action):
            answer = ctl('dispatch hl.dsp.layout(' + json.dumps(action) + ')')
            assert answer.strip() == 'ok', answer

        def patches():
            nonlocal sequence
            sequence += 1
            for folder in folders:
                temp = folder / 'patch-next'
                temp.write_text(str(sequence))
                temp.replace(folder / 'patch-state')

        def measure(mode, repeat, name, action):
            paths = [args.output / 'compositor.log', *[args.output / f'app{n}.log' for n in range(4)]]
            offsets = [p.stat().st_size for p in paths]
            before = counters(child.pid)
            action()
            time.sleep(.3)
            after = counters(child.pid)
            tails = [p.read_bytes()[offset:].decode(errors='replace') for p, offset in zip(paths, offsets)]
            stamps = re.findall(r'\[(\d+:\d+:[\d.]+)\][^\n]*-> wl_surface[#@]' + surface + r'\.commit\(', tails[0])
            commits = [sum(float(v)*unit for v, unit in zip(stamp.split(':'), (3600000, 60000, 1000))) for stamp in stamps]
            gaps = [(b - a) % 86400000 for a, b in zip(commits, commits[1:])]
            client_text = '\n'.join(tails[1:])
            client_damage = [tuple(map(int, rect)) for rect in re.findall(r'wl_surface[#@]\d+\.damage(?:_buffer)?\((\d+), (\d+), (\d+), (\d+)\)', client_text)]
            if name != 'idle' and not args.headless:
                assert commits, 'no outer commits parsed for active workload'
            if name == 'tiny-updates':
                assert any(0 < w*h <= 4096 for _, _, w, h in client_damage), 'fixture did not submit small damage'
                if args.log_damage:
                    assert 'Damage: Surface' in tails[0], 'native damage logging is inactive; zero counts are invalid'
            row = {'mode': mode, 'repeat': repeat, 'workload': name, 'seconds': after['time'] - before['time'],
                   'start_monotonic': before['time'], 'end_monotonic': after['time'],
                   'gfx_ms': (after['gfx_ns'] - before['gfx_ns']) / 1e6,
                   'cpu_ms': (after['cpu_ticks'] - before['cpu_ticks']) / os.sysconf('SC_CLK_TCK') * 1000,
                   'surface_damage_events': len(re.findall(r'Damage: Surface', tails[0])) if args.log_damage else None,
                   'full_monitor_invalidations': len(re.findall(r'Damage: Monitor WAYLAND-1', tails[0])) if args.log_damage else None,
                   'outer_commits': len(commits), 'nested_commit_gap_ms_p95': sorted(gaps)[math.ceil(len(gaps)*.95)-1] if gaps else None,
                   'client_configures': len(re.findall(r'\bxdg_toplevel[#@]\d+\.configure\(', client_text)),
                   'client_commits': len(re.findall(r'-> wl_surface[#@]\d+\.commit\(', client_text)),
                   'client_damage_rectangles': client_damage}
            if name == 'resize':
                assert row['client_configures'] == 8 and row['client_commits'] == 8, 'resize configure/commit cadence changed'
            elif not replay:
                assert row['client_configures'] == 0, 'non-resize workload unexpectedly configured clients'
            else:
                configured_sizes = set(re.findall(r'xdg_toplevel[#@]\d+\.configure\((\d+), (\d+),', client_text))
                initial_sizes = {tuple(map(str, w['size'])) for w in result['replay_initial_clients']}
                assert configured_sizes <= initial_sizes | {('0', '0')}, 'focus replay unexpectedly resized a client'
            row['frame_measurement'] = ('recorded layout-command replay' if replay else 'fixed 120-command pan workload') + '; no frame-count or presentation claim' if args.headless else 'nested outer surface commits'
            if args.headless:
                del row['outer_commits'], row['nested_commit_gap_ms_p95']
            else:
                row['gfx_ms_per_outer_commit'] = row['gfx_ms'] / len(commits) if commits else None
            result['trials'].append(row)
            print(json.dumps(row), flush=True)

        def tiny_updates():
            for _ in range(10):
                patches()
                time.sleep(.2)

        def pan():
            dispatch('pan-begin')
            start, previous = time.monotonic(), 0
            for n in range(1, 121):
                x = 80 * math.sin(2 * math.pi * n / 120)
                dispatch(f'pan {x - previous:.6f} 0')
                previous = x
                time.sleep(max(0, start + n / 60 - time.monotonic()))

        def replay_input():
            start = time.monotonic()
            result['replay_start_monotonic'] = start
            result['replayed_commands'] = []
            for event in replay:
                time.sleep(max(0, start + event['t'] - time.monotonic()))
                sent = time.monotonic()
                dispatch(event['command'])
                result['replayed_commands'].append(dict(event, sent_monotonic=sent))
            result['replay_final_clients'] = json.loads(ctl('j/clients'))

        def resize():
            for n in range(8):
                dispatch('resize ' + ('l' if n % 2 == 0 else 'h'))
                time.sleep(.4)

        for mode in (('recorded-input',) if replay else ('normal', 'overview', 'normal-returned')):
            dispatch('pan-end')
            # pan-begin cancels the commit that clears overview after its exit animation.
            time.sleep(1.5)
            if not replay:
                dispatch('pan-begin')
                if mode == 'overview':
                    dispatch('pan-overview')
                else:
                    dispatch('pan 120 0')
            time.sleep(1.5)
            for repeat in range(args.repeats):
                if not args.pan_only:
                    measure(mode, repeat, 'idle', lambda: time.sleep(1))
                    measure(mode, repeat, 'tiny-updates', tiny_updates)
                measure(mode, repeat, 'pan', replay_input if replay else pan)
                if not args.pan_only:
                    measure(mode, repeat, 'resize', resize)
                time.sleep(.5)
            row = {'mode': mode, 'freshness_checked': not args.pan_only}
            if not args.pan_only:
                video = args.output / f'{mode}.mkv'
                recorder = launch(['wf-recorder', '--no-dmabuf', '-o', monitor['name'], '-c', 'ffv1', '-x', 'bgr0', '-f', str(video)],
                                  appenv, f'{mode}-capture.log')
                time.sleep(1)
                assert recorder.poll() is None, 'recorder failed'
                capture_log = args.output / f'{mode}-capture.log'
                offset = capture_log.stat().st_size
                patches()
                wait(lambda: any((f / 'patch-drawn').read_text() == str(sequence) for f in folders), processes)
                wait(lambda: '.ready(' in capture_log.read_bytes()[offset:].decode(errors='replace'), [child, recorder])
                time.sleep(.2)
                tiny_updates()
                wait(lambda: any((f / 'patch-drawn').read_text() == str(sequence) for f in folders), [child, recorder])
                time.sleep(.3)
                recorder.send_signal(signal.SIGINT)
                patches()
                stop(recorder, signal.SIGINT)
                assert recorder.returncode == 0, 'recording did not finalize cleanly'
                processes.remove(recorder)
                trace = capture_log.read_bytes()[offset:].decode(errors='replace')
                assert '.copy_with_damage(' in trace, 'capture forced repaint; invalid damage test'
                damage = [tuple(map(int, m)) for m in re.findall(r'\.damage\((\d+), (\d+), (\d+), (\d+)\)', trace)]
                assert damage, 'no screencopy damage events'
                raw = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(video), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-fps_mode', 'passthrough', '-'], timeout=30)
                assert raw and len(raw) % (pixels * 3) == 0, 'unexpected recording dimensions'
                colors, changed = [], []
                previous = None
                for pos in range(0, len(raw), pixels * 3):
                    frame = raw[pos:pos + pixels * 3]
                    if frame == previous:
                        colors.append(colors[-1])
                        changed.append(0)
                        continue
                    green = purple = 0
                    for r, g, b in zip(frame[::3], frame[1::3], frame[2::3]):
                        green += r < 35 and g > 180 and b < 35
                        purple += r > 180 and g < 35 and b > 180
                    colors.append([green, purple])
                    if previous is not None:
                        changed.append(sum(frame[n:n+3] != previous[n:n+3] for n in range(0, len(frame), 3)))
                    previous = frame
                assert any(green > 20 for green, _ in colors) and any(purple > 20 for _, purple in colors), 'small content updates missing'
                changes = [n for n in changed if n > 0]
                assert len(changes) >= 10, 'recording lost too many small updates'
                row.update(recorded_frames=len(colors), changed_pixels=changed, median_changed_fraction=statistics.median(changes) / pixels,
                           capture_copy_rectangles=damage, capture_damage_is_not_renderer_damage=True)
                assert row['median_changed_fraction'] < .02, 'tiny-update fixture changed too much of the screen'
            else:
                patches()
            image = f'{mode}.ppm'
            wait(lambda: any((f / 'patch-drawn').read_text() == str(sequence) for f in folders), processes)
            time.sleep(.3)
            subprocess.run(['grim', '-t', 'ppm', '-o', monitor['name'], str(args.output / image)],
                           env=appenv, check=True, capture_output=True, timeout=10)
            ppm = (args.output / image).read_bytes()
            canonical = ppm.split(b'\n', 3)[3]
            assert len(canonical) == pixels * 3
            row.update(settled_image=image, settled_sha256=hashlib.sha256(ppm).hexdigest())
            if args.reference:
                expected = (args.reference / image).read_bytes().split(b'\n', 3)[3]
                row['reference_changed_pixels'] = sum(canonical[n:n+3] != expected[n:n+3] for n in range(0, len(canonical), 3))
                assert len(expected) == len(canonical) and row['reference_changed_pixels'] == 0, 'settled image differs from reference'
            result['visual'].append(row)
            print(json.dumps({'visual': row}), flush=True)
        if args.pan_only:
            assert ctl('eval hl.config({debug={pass=1}})').strip() == 'ok'
            time.sleep(.3)
            subprocess.run(['grim', '-o', monitor['name'], str(args.output / 'occlusion-debug.png')],
                           env=appenv, check=True, capture_output=True, timeout=10)
            assert ctl('eval hl.config({debug={pass=0}})').strip() == 'ok'
        assert not ctl('configerrors').strip(), ctl('configerrors')
        assert all(sha(p) == value for p, value in hashes.items()), 'inputs changed during run'
        result['passed'] = True
    finally:
        errors = []
        for proc in reversed(processes):
            try:
                stop(proc)
            except Exception as error:
                errors.append(str(error))
        if listener:
            listener.close()
        if rule_added:
            try:
                assert parent('eval ' + rule + ':set_enabled(false);' + rule + '=nil').strip() == 'ok'
            except Exception as error:
                errors.append('parent rule cleanup: ' + str(error))
        for log in logs:
            log.close()
        result['parent_binary_unchanged'] = Path(f'/proc/{parent_pid}/exe').exists() and sha(f'/proc/{parent_pid}/exe') == result['parent_binary_sha256']
        result['cleanup_errors'] = errors
        result['passed'] = result['passed'] and not errors and result['parent_binary_unchanged']
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(str(args.output / 'result.json'), flush=True)
        if errors:
            raise RuntimeError('; '.join(errors))


if __name__ == '__main__':
    main()
