#!/usr/bin/env python3
"""Measure public canvas zoom on a private hardware-backed Weston output."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rendering', ROOT / 'test-canvas-rendering.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def main():
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    signal.signal(signal.SIGINT, signal.default_int_handler)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--weston', type=Path, required=True)
    parser.add_argument('--weston-shim', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=4)
    parser.add_argument('--cycles', type=int, default=6)
    parser.add_argument('--clients', type=int, default=4)
    parser.add_argument('--damage', choices=('partial', 'full'))
    parser.add_argument('--two-rows', action='store_true')
    parser.add_argument('--motion', choices=('zoom', 'pan'), default='zoom')
    parser.add_argument('--lifecycle', action='store_true')
    parser.add_argument('--transform', type=int, choices=(0, 3), default=3)
    parser.add_argument('--cpu', type=int, required=True)
    parser.add_argument('--parent-cpu', type=int, required=True)
    parser.add_argument('--weston-cpu', type=int, required=True)
    args = parser.parse_args()
    assert not args.lifecycle or (args.clients == 16 and args.two_rows and args.transform == 3)
    args.output.mkdir(parents=True, exist_ok=False)
    width, height = (800, 1280) if args.transform == 3 else (1280, 800)
    runtime = Path(tempfile.mkdtemp(prefix='cz-'))
    config = ROOT.parents[1] / 'dotfiles/hyprland/.config/hypr/hyprland.lua'
    wrapper = args.output / 'hyprland.lua'
    wrapper.write_text('package.path=' + json.dumps(str(config.parent / '?.lua') + ';') + '..package.path\n'
                       'local on=hl.on\nhl.on=function(e,cb) if e~="hyprland.start" then return on(e,cb) end end\n'
                       'dofile(' + json.dumps(str(config)) + ')\nhl.on=on\n'
                       'hl.config({misc={disable_splash_rendering=true},debug={disable_logs=false},experimental={canvas_vignette=0.85}})\n'
                       f'hl.monitor({{output="WAYLAND-1",mode="{width}x{height}@90",scale=1,transform={args.transform}}})\n')
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(args.output / 'state'),
               XDG_CONFIG_HOME=str(args.output / 'config'), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='deck',
               HYPR_SCRIPTS=str(args.output / 'missing') + '/')
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NIRI_SOCKET', 'SWAYSOCK', 'NOTIFY_SOCKET'):
        env.pop(key, None)
    processes, logs = [], []
    result = {'passed': False, 'trials': [], 'captures': {}, 'binary': r.sha(args.binary),
              'parent_binary': r.sha(args.parent_binary), 'runner': r.sha(__file__), 'config': {str(p.relative_to(config.parent)): r.sha(p) for p in config.parent.rglob('*.lua')},
              'weston': r.sha(args.weston), 'weston_shim': r.sha(args.weston_shim), 'cycles': args.cycles, 'repeats': args.repeats,
              'measurement': 'Private Weston headless GL; nested commits are not physical presentation or Deck FPS.',
              'platform_profile': Path('/sys/firmware/acpi/platform_profile').read_text().strip(),
              'cpus': {'candidate': args.cpu, 'bridge': args.parent_cpu, 'weston': args.weston_cpu},
              'workload': {'clients': args.clients, 'damage': args.damage, 'two_rows': args.two_rows, 'motion': args.motion, 'lifecycle': args.lifecycle},
              'client_fixture': r.sha(ROOT / 'test-canvas-visuals.py')}
    assert len(set(result['cpus'].values())) == 3
    affinity = {'compositor.log': args.cpu, 'bridge.log': args.parent_cpu, 'parent.log': args.weston_cpu}
    listener = socket.socket(socket.AF_UNIX)
    bridge_listener = socket.socket(socket.AF_UNIX)

    def launch(command, environment, name, **kwargs):
        f = (args.output / name).open('w')
        logs.append(f)
        pin = (lambda: os.sched_setaffinity(0, {affinity[name]})) if name in affinity else None
        p = subprocess.Popen(command, env=environment, stdout=f, stderr=subprocess.STDOUT, preexec_fn=pin, **kwargs)
        processes.append(p)
        return p

    try:
        parent = launch([str(args.weston), '--backend=headless', '--renderer=gl', '--width=1280', '--height=800',
                         '--refresh-rate=90000', '--socket=parent', '--idle-time=0', '--no-config', '--fake-seat',
                         '--log=' + str(args.output / 'weston.log')], dict(env, EGL_PLATFORM='surfaceless', LD_PRELOAD=str(args.weston_shim)), 'parent.log')
        r.wait(lambda: (runtime / 'parent').exists(), [parent])
        bridge_listener.bind(str(runtime / 'bridge'))
        bridge_listener.listen(16)
        bridge = launch([str(args.parent_binary), '--socket', 'bridge', '--wayland-fd', str(bridge_listener.fileno()), '--config', str(wrapper)],
                        dict(env, WAYLAND_DISPLAY='parent', EGL_PLATFORM='wayland', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none'),
                        'bridge.log', pass_fds=(bridge_listener.fileno(),))
        bridge_instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None), [bridge])
        bctl = lambda command: r.ipc(bridge_instance, command)
        assert not bctl('configerrors').strip(), bctl('configerrors')
        assert bctl('eval hl.monitor({output="HEADLESS-1",mode="800x1280@90",position="0x0",scale=1,transform=3})').strip() == 'ok'
        assert bctl('output create headless HEADLESS-1').strip() == 'ok'
        r.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(bctl('j/monitors'))), [bridge])
        assert bctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
        assert bctl(f'eval hl.window_rule({{name="nested",match={{class="^aquamarine$"}},float=true,size="{width} {height}",no_initial_focus=true,no_focus=true,render_unfocused=true}})').strip() == 'ok'
        result['parent_monitors'] = json.loads(bctl('j/monitors'))
        listener.bind(str(runtime / 'candidate'))
        listener.listen(16)
        child = launch([str(args.binary), '--socket', 'candidate', '--wayland-fd', str(listener.fileno()), '--config', str(wrapper)],
                       dict(env, WAYLAND_DISPLAY='bridge', EGL_PLATFORM='wayland', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none', WAYLAND_DEBUG='client'),
                       'compositor.log', pass_fds=(listener.fileno(),))
        instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if p != bridge_instance and (p / '.socket.sock').exists()), None), [child])
        ctl = lambda command: r.ipc(instance, command)
        assert not ctl('configerrors').strip(), ctl('configerrors')
        appenv = dict(env, WAYLAND_DISPLAY='candidate', GDK_BACKEND='wayland')
        launch(['swaybg', '-c', '#374d68'], appenv, 'background.log')
        for n in range(args.clients):
            p = launch(['python3', str(ROOT / 'test-canvas-visuals.py'), '--client', str(args.output / f'app{n}'), str(n % 4)],
                       dict(appenv, **({'CANVAS_ZOOM_DAMAGE': args.damage} if args.damage else {})), f'app{n}.log')
            r.wait(lambda: len(json.loads(ctl('j/clients'))) == n + 1, [child, p])
            time.sleep(.3)
        if args.two_rows:
            for window in reversed(json.loads(ctl('j/clients'))[-args.clients // 2:]):
                assert ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + window['address']) + '})').strip() == 'ok'
                assert ctl('dispatch hl.dsp.layout("move j")').strip() == 'ok'
                time.sleep(.3)
        time.sleep(16)
        result['monitors'] = json.loads(ctl('j/monitors'))
        assert [(m['width'], m['height'], m['transform']) for m in result['monitors']] == [(width, height, args.transform)]
        result['clients'] = json.loads(ctl('j/clients'))
        assert os.sched_getaffinity(child.pid) == {args.cpu}
        assert os.sched_getaffinity(bridge.pid) == {args.parent_cpu}
        assert os.sched_getaffinity(parent.pid) == {args.weston_cpu}
        result['options'] = {key: json.loads(ctl('j/getoption experimental:' + key)) for key in
                             ('canvas_lens', 'canvas_lens_strength', 'canvas_lens_edge_scale', 'canvas_vignette',
                              'canvas_backdrop_blur', 'canvas_parallax_strength', 'canvas_parallax_depth')}
        text = (args.output / 'compositor.log').read_text()
        result['renderer'] = re.findall(r'Renderer: (.*)', (instance / 'hyprland.log').read_text())
        assert result['renderer'] and not any(x in str(result['renderer']).lower() for x in ('llvmpipe', 'softpipe'))
        surface = re.search(r'get_xdg_surface\([^\n]*wl_surface[#@](\d+)\)', text)[1]

        def dispatch(command):
            result.setdefault('dispatches', []).append({'time': time.monotonic(), 'wall_time': time.time(), 'command': command})
            answer = ctl('dispatch hl.dsp.layout(' + json.dumps(command) + ')').strip()
            assert answer == 'ok', answer

        def shot(name):
            path = args.output / (name + '.png')
            subprocess.run(['grim', '-o', 'WAYLAND-1', str(path)], env=appenv, check=True, timeout=10)
            result['captures'][name] = r.sha(path)

        def cycles(count):
            for _ in range(count):
                dispatch('overview')
                time.sleep(1.4)
                if args.motion == 'pan':
                    for direction in (-1, 1):
                        for _ in range(8):
                            dispatch(f'pan {direction * 160} 0')
                            time.sleep(.1)
                    time.sleep(.6)
                dispatch('overview')
                time.sleep(1.4)

        def animate(active):
            if args.damage:
                for n in range(args.clients):
                    marker = args.output / f'app{n}' / 'animate'
                    marker.touch() if active else marker.unlink()
                time.sleep(.3)

        shot('normal')
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
        for repeat in range(args.repeats):
            path = args.output / 'compositor.log'
            offset = path.stat().st_size
            before = r.counters(child.pid)
            cycles(args.cycles)
            after = r.counters(child.pid)
            with path.open() as f:
                f.seek(offset)
                tail = f.read()
            frames = len(re.findall(r'-> wl_surface[#@]' + surface + r'\.commit\(', tail))
            assert frames > args.cycles * 20, frames
            row = {'repeat': repeat, 'frames': frames, 'start': before['time'], 'end': after['time'], 'seconds': after['time'] - before['time'],
                   'cpu_ms': (after['cpu_ticks'] - before['cpu_ticks']) * 1000 / os.sysconf('SC_CLK_TCK'),
                   'gpu_ms': (after['gfx_ns'] - before['gfx_ns']) / 1e6}
            stamps = re.findall(r'\[(\d+):(\d+):([\d.]+)\][^\n]*-> wl_surface[#@]' + surface + r'\.commit\(', tail)
            commits = [(int(h) * 3600 + int(m) * 60 + float(s)) * 1000 for h, m, s in stamps]
            intervals = sorted(b - a for a, b in zip(commits, commits[1:]))
            assert intervals, 'missing commit timestamps'
            row.update(cpu_ms_per_frame=row['cpu_ms'] / frames, gpu_ms_per_frame=row['gpu_ms'] / frames,
                       commit_interval_p50_ms=statistics.median(intervals), commit_interval_p95_ms=intervals[int(len(intervals) * .95)],
                       commit_interval_p99_ms=intervals[int(len(intervals) * .99)], commit_interval_max_ms=max(intervals),
                       commits_over_25ms=sum(x > 25 for x in intervals))
            result['trials'].append(row)
            print(json.dumps(row), flush=True)
        result['memory_high_water_kb'] = int(re.search(r'VmHWM:\s*(\d+)', Path(f'/proc/{child.pid}/status').read_text())[1])
        animate(False)
        time.sleep(1)
        shot('returned')
        assert result['captures']['returned'] == result['captures']['normal'], 'zoom round-trip changed the settled frame'
        assert result['captures']['overview'] != result['captures']['normal']
        assert result['captures']['panned'] != result['captures']['overview']
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
        lock = launch(['swaylock' , '--config', '/dev/null', '--color', '00000000'], dict(appenv, WAYLAND_DEBUG='client'), 'lock.log')
        r.wait(lambda: 'ext_session_lock_v1' in (args.output / 'lock.log').read_text() and '.locked(' in (args.output / 'lock.log').read_text(), [child, lock])
        time.sleep(2)
        locked = args.output / 'locked.png'
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(locked)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
        result['captures']['locked'] = r.sha(locked)
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
            lock.terminate()
            lock.wait(timeout=10)
            time.sleep(5)
            missing = args.output / 'missing-lock.png'
            subprocess.run(['grim', '-o', 'HEADLESS-1', str(missing)], env=dict(appenv, WAYLAND_DISPLAY='bridge'), check=True, timeout=10)
            assert r.sha(missing) != r.sha(locked), 'missing lock surface did not change the secure fallback'
            result['missing_lock_fallback'] = True
        result['passed'] = True
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
                    result.setdefault('cleanup_errors', []).append(p.args)
        listener.close()
        bridge_listener.close()
        for log in logs:
            log.close()
        result['passed'] = result['passed'] and not result.get('cleanup_errors')
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    assert result['passed'], result.get('cleanup_errors')


if __name__ == '__main__':
    main()
