#!/usr/bin/env python3
"""Canvas window groups on a private headless output: joins, narrow gaps, camera framing, leaving, persistence."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rendering', ROOT / 'test-canvas-rendering.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

ACCENTS = [(102, 204, 230), (230, 179, 102), (153, 179, 243)]
WIDTH, HEIGHT = 1920, 1080
OUTER_GAP, INNER_GAP = 24, 64
BORDER = 2  # j/clients reports the client box inside the window border


def main():
    global WIDTH, HEIGHT
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True, help='live /run/user/UID/hypr/INSTANCE, used only for a temporary hiding rule')
    parser.add_argument('--output', type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--quick-navigation', action='store_true')
    modes.add_argument('--profile-gpu', action='store_true')
    parser.add_argument('--wallpaper', type=Path)
    args = parser.parse_args()
    if args.profile_gpu:
        if not args.wallpaper or not args.wallpaper.is_file():
            parser.error('--profile-gpu requires an existing --wallpaper image')
        WIDTH, HEIGHT = 3840, 2400
    if args.quick_navigation or args.profile_gpu:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(124))
    args.output.mkdir(parents=True, exist_ok=True)
    # Leave room for the generated instance name and .socket2.sock within Unix's path limit.
    runtime = Path(tempfile.mkdtemp(prefix='c', dir=os.environ['XDG_RUNTIME_DIR']))
    runtime.chmod(0o700)
    live = lambda command: r.ipc(args.parent_instance, command)
    if args.profile_gpu:
        time.sleep(.75)
    parent_focus = json.loads(live('j/activewindow')).get('address')
    parent_pid = (args.parent_instance / 'hyprland.lock').read_text().splitlines()[0]
    parent_binary = r.sha(f'/proc/{parent_pid}/exe')
    live_display = os.environ['WAYLAND_DISPLAY']
    env = {k: v for k, v in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NOTIFY_SOCKET')}
    env.update(XDG_RUNTIME_DIR=str(runtime), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none')
    rule = 'canvas_groups_test_' + str(os.getpid())
    processes, logs = [], []

    def launch(command, environment, path, **kwargs):
        log = path.open('w')
        logs.append(log)
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        processes.append(process)
        return process

    assert live('eval ' + rule + '=hl.window_rule({name="' + rule + '",match={class="^aquamarine$"},workspace="special:' + rule
                + ' silent",float=true,no_initial_focus=true,no_focus=true})').strip() == 'ok'
    results = []
    try:
        directory = args.output
        config = directory / 'hyprland.lua'
        config.write_text('package.path=' + json.dumps(str(r.CONFIG.resolve().parent) + '/?.lua;') + '..package.path\nlocal on=hl.on\nhl.on=function(event,cb) if event~="hyprland.start" then return on(event,cb) end end\n'
                          + 'dofile(' + json.dumps(str(r.CONFIG.resolve())) + ')\nhl.on=on\nhl.config({misc={disable_splash_rendering=true}})\n')
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / 'nested'))
        listener.listen(16)
        child_env = dict(env, XDG_STATE_HOME=str(directory / 'state'), XDG_CONFIG_HOME=str(directory / 'config'),
                         WAYLAND_DISPLAY=str(Path(os.environ['XDG_RUNTIME_DIR']) / live_display))
        compositor = launch([str(args.binary), '--socket', 'nested', '--wayland-fd', str(listener.fileno()), '--config', str(config)],
                            child_env, directory / 'compositor.log', pass_fds=(listener.fileno(),))
        instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None)
                          if (runtime / 'hypr').exists() else None, [compositor])
        ctl = lambda command: r.ipc(instance, command)
        assert not ctl('configerrors').strip(), ctl('configerrors')
        refresh, scale = (120, 5 / 3) if args.profile_gpu else (60, 1)
        assert ctl(f'eval hl.monitor({{output="HEADLESS-1",mode="{WIDTH}x{HEIGHT}@{refresh}",position="0x0",scale={scale}}})').strip() == 'ok'
        assert ctl('output create headless HEADLESS-1').strip() == 'ok'
        r.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [compositor])
        assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
        r.wait(lambda: [m['name'] for m in json.loads(ctl('j/monitors'))] == ['HEADLESS-1'], [compositor])
        appenv = dict(child_env, WAYLAND_DISPLAY='nested', GDK_BACKEND='wayland', HYPRLAND_INSTANCE_SIGNATURE=instance.name)
        background = ['swaybg', '-i', str(args.wallpaper.resolve()), '-m', 'fill'] if args.wallpaper else ['swaybg', '-c', '#263344']
        launch(background, appenv, directory / 'wallpaper.log')

        def command(value):
            reply = ctl(value).strip()
            assert reply == 'ok', (value, reply)

        def layout(value, settle=1.4):
            command('dispatch hl.dsp.layout(' + json.dumps(value) + ')')
            time.sleep(settle)

        def clients():
            return {w['title']: w for w in json.loads(ctl('j/clients'))}

        def focus(title, settle=1.4):
            command('dispatch hl.dsp.focus({window=' + json.dumps('address:' + clients()[title]['address']) + '})')
            time.sleep(settle)

        def screen(label):
            path = directory / (label + '.ppm')
            subprocess.run(['grim', '-t', 'ppm', '-o', 'HEADLESS-1', str(path)], env=appenv, check=True, capture_output=True, timeout=10)
            data = path.read_bytes()
            header = data.split(b'\n', 3)
            assert header[0] == b'P6' and header[1] == f'{WIDTH} {HEIGHT}'.encode(), header[:3]
            raw = header[3]
            spans = {}
            for y in range(HEIGHT):
                line = raw[y * WIDTH * 3:(y + 1) * WIDTH * 3]
                for n, accent in enumerate(ACCENTS):
                    color = bytes(accent)
                    if n not in spans and line.count(color) > 40:
                        first, last = line.find(color), line.rfind(color)
                        spans[n] = (first // 3, last // 3 + 1)
            return spans

        def check(name, condition, detail):
            results.append({'check': name, 'passed': bool(condition), 'detail': detail})
            print(('PASS ' if condition else 'FAIL ') + name + ': ' + json.dumps(detail))

        titles = []
        for n in range(3):
            launch([sys.executable, str(ROOT / 'test-canvas-visuals.py'), '--client', str(directory / f'app{n}'), str(n)], appenv, directory / f'app{n}.log')
            r.wait(lambda: len(clients()) == n + 1 and (directory / f'app{n}/size').exists(), [compositor])
            time.sleep(.4)
        names = ['Editor / canvas.cpp', 'Notes / visual language', 'Browser / project']
        a, b, c = names
        row_y = {round(clients()[t]['at'][1]) for t in names}
        assert len(row_y) == 1, ('fixtures must share a row', {t: (w['at'], w['size'], w['floating'], w['workspace']['name']) for t, w in clients().items()}, json.loads(ctl('j/monitors'))[0]['reserved'])
        order = sorted(names, key=lambda t: clients()[t]['at'][0])
        a, b, c = order
        gap = lambda left, right: clients()[right]['at'][0] - (clients()[left]['at'][0] + clients()[left]['size'][0]) - 2 * BORDER
        check('ungrouped gap', abs(gap(a, b) - INNER_GAP) <= 1, gap(a, b))
        index = {t: names.index(t) for t in names}

        if args.profile_gpu:
            metrics = {'parent_focus_initial': parent_focus, 'binary_sha256': r.sha(args.binary),
                       'config_sha256': r.sha(r.CONFIG), 'runner_sha256': r.sha(Path(__file__)),
                       'wallpaper_sha256': r.sha(args.wallpaper), 'width': WIDTH, 'height': HEIGHT, 'scale': scale,
                       'scope': 'private per-stage GPU timestamps, not physical frame pacing',
                       'parent_focus_before_measurement': json.loads(live('j/activewindow')).get('address')}
            assert metrics['parent_focus_before_measurement'] == parent_focus, 'parent focus changed during setup'

            def still(label):
                subprocess.run(['grim', '-t', 'ppm', '-o', 'HEADLESS-1', str(directory / (label + '.ppm'))], env=appenv, check=True, capture_output=True, timeout=10)

            for cycle in range(3):
                layout('overview', 1.6 if cycle == 0 else .8)
                if cycle == 0:
                    still('overview')
                for _ in range(8):
                    layout('pan 36 12', .05)
                if cycle == 0:
                    time.sleep(1.5)
                    still('overview-panned')
                layout('overview', .8)
            return

        if args.quick_navigation:
            metrics = {'parent_focus_initial': parent_focus, 'binary_sha256': r.sha(args.binary), 'config_sha256': r.sha(r.CONFIG),
                       'runner_sha256': r.sha(Path(__file__)), 'scope': 'private IPC/main-thread diagnostic; not physical frame pacing', 'runs': []}
            addresses = {t: clients()[t]['address'].removeprefix('0x') for t in names}
            for grouped in (False, True):
                focus(a, .8)
                if grouped:
                    layout('join l', .8)
                with socket.socket(socket.AF_UNIX) as events:
                    events.connect(str(instance / '.socket2.sock'))
                    events.setblocking(False)
                    samples = []
                    cpu_before = int(Path(f'/proc/{compositor.pid}/schedstat').read_text().split()[0])
                    for direction in ['l', 'h'] * 12:
                        started = time.perf_counter_ns()
                        command('dispatch hl.dsp.layout(' + json.dumps('focus ' + direction) + ')')
                        samples.append((time.perf_counter_ns() - started) / 1e6)
                        time.sleep(.12)
                    cpu_after = int(Path(f'/proc/{compositor.pid}/schedstat').read_text().split()[0])
                    received = b''
                    while True:
                        try:
                            chunk = events.recv(65536)
                        except BlockingIOError:
                            break
                        assert chunk, 'focus event socket closed'
                        received += chunk
                observed = [line.split('>>', 1)[1] for line in received.decode().splitlines() if line.startswith('activewindowv2>>')]
                path = [addresses[a]]
                for address in observed:
                    if address != path[-1]:
                        path.append(address)
                check('grouped navigation' if grouped else 'ordinary navigation',
                      path == [addresses[a]] + [addresses[b], addresses[a]] * 12, path)
                check('final keyboard focus', json.loads(ctl('j/activewindow'))['title'] == a, a)
                metrics['runs'].append({'grouped': grouped, 'commands': len(samples), 'focus_events': len(observed),
                                        'ipc_ms': samples, 'median_ipc_ms': statistics.median(samples),
                                        'p95_ipc_ms': sorted(samples)[int((len(samples) - 1) * .95)],
                                        'main_thread_cpu_ms': (cpu_after - cpu_before) / 1e6})
                print(json.dumps(metrics['runs'][-1]), flush=True)
                if grouped:
                    layout('join l', .8)
            focus(a, .8)
            centered = screen('edge-centered')
            layout('pan -120 0', .4)
            layout('focus h')
            check('no-neighbor navigation restores framing', screen('edge-restored') == centered, centered)
            assert all(item['passed'] for item in results), results
            return

        focus(a)
        layout('join l')
        wide = screen('wide-entered')
        span_a = wide.get(index[a])
        check('a group too wide to fit pins the focused window to the edge away from its neighbour',
              span_a and abs(span_a[0] - OUTER_GAP - BORDER) <= 2, {'a': span_a, 'b': wide.get(index[b])})
        layout('focus l')
        wide = screen('wide-right')
        span_b = wide.get(index[b])
        check('moving right inside a wide group pins the window to the right edge, neighbour peeking left',
              span_b and abs(span_b[1] - (WIDTH - OUTER_GAP - BORDER)) <= 2 and wide.get(index[a]) is not None, {'a': wide.get(index[a]), 'b': span_b})
        layout('focus h')
        wide = screen('wide-left')
        check('moving back pins the left window to the left edge', wide.get(index[a]) and abs(wide.get(index[a])[0] - OUTER_GAP - BORDER) <= 2, wide.get(index[a]))
        layout('join l')
        check('leaving restores the normal gap', abs(gap(a, b) - INNER_GAP) <= 1, gap(a, b))

        for title in names:
            focus(title, .6)
            layout('resize h', .6)

        focus(a)
        layout('join l')
        check('joined gap is the edge margin', abs(gap(a, b) - OUTER_GAP) <= 1, gap(a, b))
        check('other neighbour keeps the normal gap', abs(gap(b, c) - INNER_GAP) <= 1, gap(b, c))
        framed = screen('framed')
        left, right = framed.get(index[a]), framed.get(index[b])
        check('entering frames the whole group', left and right and left[0] >= 0 and right[1] <= WIDTH and abs(left[0] - (WIDTH - right[1])) <= 3,
              {'a': left, 'b': right})

        layout('focus l')
        inside = screen('inside')
        check('focus inside the group keeps the camera still', inside == framed, {'before': framed, 'after': inside})
        check('focus moved', json.loads(ctl('j/activewindow'))['title'] == b, json.loads(ctl('j/activewindow'))['title'])

        focus(a)
        mouse = screen('mouse-inside')
        check('focus by address inside the group keeps the camera still', mouse == framed, {'before': framed, 'after': mouse})

        focus(b)
        layout('focus l')
        outside = screen('outside')
        third = outside.get(index[c])
        check('leaving the group centers the next window', third and abs((third[0] + third[1]) / 2 - WIDTH / 2) <= 3, third)

        layout('focus h')
        back = screen('reentered')
        check('re-entering frames the group again', back.get(index[a]) == framed.get(index[a]) and back.get(index[b]) == framed.get(index[b]), {'framed': framed, 'now': back})

        state = (directory / 'state/hypr-canvas/layout.lua').read_text()
        check('groups persist in the canvas state', '["groups"]' in state, state.count('groups'))

        layout('join h')
        check('joining toward a member leaves the group', abs(gap(a, b) - INNER_GAP) <= 1, gap(a, b))
        focus(a)
        layout('focus l')
        left_again = screen('left')
        middle = left_again.get(index[b])
        check('ungrouped focus centers again', middle and abs((middle[0] + middle[1]) / 2 - WIDTH / 2) <= 3, middle)

        focus(a)
        layout('join l')
        focus(c)
        layout('join h')
        check('an ungrouped window joins a group', abs(gap(b, c) - OUTER_GAP) <= 1 and abs(gap(a, b) - OUTER_GAP) <= 1, [gap(a, b), gap(b, c)])
        focus(b)
        layout('join l')
        check('detaching toward a member cuts the group on that side only', abs(gap(a, b) - OUTER_GAP) <= 1 and abs(gap(b, c) - INNER_GAP) <= 1,
              [gap(a, b), gap(b, c)])
        layout('join j')
        check('detaching away from the group leaves it', abs(gap(a, b) - INNER_GAP) <= 1, gap(a, b))

        focus(c)
        layout('move j')
        layout('join k')
        boxes = clients()
        vertical = None
        for t in names:
            if t != c and abs(boxes[c]['at'][1] - (boxes[t]['at'][1] + boxes[t]['size'][1]) - 2 * BORDER - OUTER_GAP) <= 1:
                vertical = t
        check('a window joined to the row above sits one edge margin below it', vertical is not None,
              {t: [boxes[t]['at'], boxes[t]['size']] for t in names})

        alone = screen('vertical-alone').get(index[c])
        check('a window alone on its row centers even when grouped vertically', alone and abs((alone[0] + alone[1]) / 2 - WIDTH / 2) <= 3, alone)
        layout('join j')
        boxes = clients()
        check('detaching downward with nothing below leaves the vertical group',
              not any(t != c and abs(boxes[c]['at'][1] - (boxes[t]['at'][1] + boxes[t]['size'][1]) - 2 * BORDER - OUTER_GAP) <= 1 for t in names),
              {t: [boxes[t]['at'], boxes[t]['size']] for t in names})

        binds = json.loads(ctl('j/binds'))
        u = [x for x in binds if x.get('key') == 'u' and x.get('modmask') == 65]
        joins = [x for x in binds if x.get('key') in ('h', 'j', 'k', 'l') and x.get('modmask') == 69]
        check('Super+Shift+U is bound and Super+Ctrl+Shift+hjkl join', len(u) == 1 and len(joins) == 4,
              {'u': u, 'joins': [{k: x.get(k) for k in ('key', 'dispatcher', 'arg', 'description')} for x in joins]})
    finally:
        if (args.quick_navigation or args.profile_gpu) and 'metrics' in locals():
            metrics['parent_focus_before_cleanup'] = json.loads(live('j/activewindow')).get('address')
        for process in reversed(processes):
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
        r.wait(lambda: not any(w['workspace']['name'] == 'special:' + rule for w in json.loads(live('j/clients'))), [])
        assert live('eval ' + rule + ':set_enabled(false);' + rule + '=nil').strip() == 'ok'
        for log in logs:
            log.close()
        (args.output / 'result.json').write_text(json.dumps(results, indent=2))
        if args.quick_navigation or args.profile_gpu:
            after = json.loads(live('j/activewindow')).get('address')
            if 'metrics' in locals():
                metrics['parent_focus_after_cleanup'] = after
                (args.output / ('gpu-profile.json' if args.profile_gpu else 'quick-navigation.json')).write_text(json.dumps(metrics, indent=2))
            assert after == parent_focus, ('parent focus changed', parent_focus, after)
            if args.profile_gpu and 'metrics' in locals():
                assert metrics['parent_focus_before_cleanup'] == parent_focus, 'parent focus changed during capture'
            assert r.sha(f'/proc/{parent_pid}/exe') == parent_binary, 'parent compositor changed'
    failed = [x for x in results if not x['passed']]
    print(f'{len(results) - len(failed)}/{len(results)} checks passed')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
