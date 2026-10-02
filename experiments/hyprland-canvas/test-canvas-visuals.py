#!/usr/bin/env python3
"""Matched visual transitions and A/B/A cost on a private GPU-backed desktop."""
import argparse
import ctypes as c
from datetime import datetime, timezone
import importlib.util
import json
import math
import os
from pathlib import Path
import re
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


def client(folder, number):
    folder.mkdir()
    gtk = c.CDLL('/nix/store/yl5yl395iqx88kd1m7lx7p7b65n0jfx9-gtk+3-3.24.51/lib/libgtk-3.so.0')
    def fn(name, result, *args):
        f = getattr(gtk, name)
        f.restype, f.argtypes = result, list(args)
        return f
    p, i, d, s = c.c_void_p, c.c_int, c.c_double, c.c_char_p
    fn('g_set_prgname', None, s)(b'canvas-visual-fixture')
    assert fn('gtk_init_check', i, p, p)(None, None)
    window = fn('gtk_window_new', p, i)(0)
    titles = ['Editor / canvas.cpp', 'Notes / visual language', 'Browser / project', 'Terminal / build']
    fn('gtk_window_set_title', None, p, s)(window, titles[number].encode())
    fn('gtk_window_set_decorated', None, p, i)(window, 0)
    fn('gtk_window_set_default_size', None, p, i, i)(window, 720, 520)
    area = fn('gtk_drawing_area_new', p)()
    fn('gtk_container_add', None, p, p)(window, area)
    def rectangle(cr, x, y, w, h, color):
        fn('cairo_set_source_rgb', None, p, d, d, d)(cr, *color)
        fn('cairo_rectangle', None, p, d, d, d, d)(cr, x, y, w, h)
        fn('cairo_fill', None, p)(cr)
    def text(cr, x, y, value, size, color):
        fn('cairo_set_source_rgb', None, p, d, d, d)(cr, *color)
        fn('cairo_select_font_face', None, p, s, i, i)(cr, b'monospace', 0, 0)
        fn('cairo_set_font_size', None, p, d)(cr, size)
        fn('cairo_move_to', None, p, d, d)(cr, x, y)
        fn('cairo_show_text', None, p, s)(cr, value.encode())
    damage_frame = 0
    @c.CFUNCTYPE(i, p, p, p)
    def draw(widget, cr, data):
        w = fn('gtk_widget_get_allocated_width', i, p)(widget)
        h = fn('gtk_widget_get_allocated_height', i, p)(widget)
        rectangle(cr, 0, 0, w, h, (.075, .085, .11))
        rectangle(cr, 0, 0, w, 56, (.11, .125, .16))
        accent = [(.4,.8,.9),(.9,.7,.4),(.6,.7,.95),(.6,.85,.6)][number]
        rectangle(cr, 0, 56, w, 2, accent)
        text(cr, 22, 35, titles[number], 18, (.9,.92,.95))
        for line, value in enumerate(['WORKSPACE / 01', '', 'A quieter space to think.', 'Tiled windows. Keyboard first.', '', 'const camera = focus.center();', 'render(world, camera);']):
            text(cr, 28, 100 + line * 30, value, 15, accent if line == 0 else (.68,.73,.81))
        for n in range(3):
            rectangle(cr, 28, h - 120 + n * 24, min(w - 56, 270 + n * 47), 10, (.16,.18,.23))
        if damage_frame:
            rectangle(cr, 32, 64, 24, 24, (damage_frame % 2, .4, .6))
            if os.getenv('CANVAS_ZOOM_DAMAGE') == 'full':
                for row in range(10):
                    text(cr, 28, 120 + row * 30, f'build output {damage_frame:06d} / {row}', 15, accent)
        (folder / 'size').write_text(f'{w} {h}')
        return 0
    @c.CFUNCTYPE(i, p, p, p)
    def key(widget, event, data):
        value = c.c_uint()
        fn('gdk_event_get_keyval', i, p, p)(event, c.byref(value))
        with (folder / 'keys').open('a') as out:
            out.write(str(value.value) + '\n')
        return 0
    @c.CFUNCTYPE(i, p, p, p)
    def click(widget, event, data):
        x, y = c.c_double(), c.c_double()
        fn('gdk_event_get_coords', i, p, p, p)(event, c.byref(x), c.byref(y))
        with (folder / 'clicks').open('a') as out:
            out.write(json.dumps([x.value, y.value]) + '\n')
        return 0
    connect = fn('g_signal_connect_data', c.c_ulong, p, s, p, p, p, i)
    connect(area, b'draw', c.cast(draw, p), None, None, 0)
    connect(window, b'key-press-event', c.cast(key, p), None, None, 0)
    fn('gtk_widget_add_events', None, p, i)(area, 1 << 8)
    connect(area, b'button-press-event', c.cast(click, p), None, None, 0)
    fn('gtk_widget_show_all', None, p)(window)
    @c.CFUNCTYPE(i, p)
    def repaint(data):
        nonlocal damage_frame
        active = (folder / 'animate').exists()
        if not active and not damage_frame:
            return 1
        damage_frame = damage_frame + 1 if active else 0
        if os.getenv('CANVAS_ZOOM_DAMAGE') == 'partial':
            fn('gtk_widget_queue_draw_area', None, p, i, i, i, i)(area, 32, 64, 24, 24)
        else:
            fn('gtk_widget_queue_draw', None, p)(area)
        return 1
    if os.getenv('CANVAS_ZOOM_DAMAGE'):
        fn('g_timeout_add', c.c_uint, c.c_uint, p, p)(16, c.cast(repaint, p), None)
    fn('gtk_main', None)()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--scale', type=float, default=1)
    parser.add_argument('--resolution', default='1440x900')
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--candidate-only', action='store_true')
    parser.add_argument('--candidate-config', type=Path)
    parser.add_argument('--baseline-config', type=Path)
    parser.add_argument('--candidate-base-config', type=Path)
    parser.add_argument('--baseline-base-config', type=Path)
    parser.add_argument('--baseline-lens', action='store_true')
    parser.add_argument('--fit-overview', action='store_true')
    parser.add_argument('--wallpaper', type=Path)
    parser.add_argument('--focus-sequences', action='store_true')
    parser.add_argument('--key-sender', type=Path)
    parser.add_argument('--tuning-tests', action='store_true')
    parser.add_argument('--lens-tests', action='store_true')
    parser.add_argument('--normal-pan-tests', action='store_true')
    parser.add_argument('--backdrop-tests', action='store_true')
    parser.add_argument('--framing-smoke', action='store_true')
    parser.add_argument('--minimap-smoke', action='store_true')
    parser.add_argument('--effect-tests', action='store_true')
    parser.add_argument('--floating-tests', action='store_true')
    args = parser.parse_args()
    width, height = map(int, args.resolution.split('x'))
    args.output.mkdir(parents=True, exist_ok=False)
    runtime = Path(tempfile.mkdtemp(prefix='cv-'))
    live_pid, live_display = (args.parent_instance / 'hyprland.lock').read_text().splitlines()
    live = lambda command: r.ipc(args.parent_instance, command)
    live_hash = r.sha(f'/proc/{live_pid}/exe')
    input_hashes = {str(p): r.sha(p) for p in (args.baseline, args.candidate, r.CONFIG, r.CONFIG.with_name('canvas-state.lua'), Path(__file__))}
    for config in (args.candidate_config, args.baseline_config, args.candidate_base_config, args.baseline_base_config, args.wallpaper):
        if config:
            input_hashes[str(config.resolve())] = r.sha(config)
    if args.tuning_tests:
        for path in [ROOT / 'canvas_tuning_test.py', *(ROOT / 'tuning').glob('*')]:
            if path.is_file():
                input_hashes[str(path)] = r.sha(path)
    if args.lens_tests:
        for filename in ('canvas_lens_test.py', 'test-canvas-x11-input.py', 'test-canvas-rendering.py', 'canvas-key-sequence.c'):
            input_hashes[str(ROOT / filename)] = r.sha(ROOT / filename)
    if args.floating_tests:
        for filename in ('canvas_floating_test.py', 'test-canvas-x11-input.py'):
            input_hashes[str(ROOT / filename)] = r.sha(ROOT / filename)
    if args.normal_pan_tests:
        input_hashes[str(ROOT / 'canvas_interaction_test.py')] = r.sha(ROOT / 'canvas_interaction_test.py')
    if args.effect_tests:
        input_hashes[str(ROOT / 'canvas_effects_test.py')] = r.sha(ROOT / 'canvas_effects_test.py')
    if args.focus_sequences:
        input_hashes[str(ROOT / 'measure-canvas-focus.py')] = r.sha(ROOT / 'measure-canvas-focus.py')
    if args.focus_sequences or args.tuning_tests or args.lens_tests:
        assert args.key_sender, 'input tests require --key-sender'
        input_hashes[str(args.key_sender)] = r.sha(args.key_sender)
    env = os.environ.copy()
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NOTIFY_SOCKET', 'NIRI_SOCKET', 'SWAYSOCK'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none')
    processes, logs, listeners = [], [], []
    rule = 'canvas_visual_test_' + str(os.getpid())
    result = {'passed': False, 'hashes': input_hashes, 'scale': args.scale, 'runs': [], 'hardware': live('j/monitors'),
              'measurement': 'GPU-backed nested submissions, not physical presentation times', 'cleanup_errors': []}
    def launch(command, environment, path, **kwargs):
        log = path.open('w')
        logs.append(log)
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        processes.append(process)
        return process
    def stop(process):
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=15)
        processes.remove(process)
    def compositor(binary, directory, display, name):
        directory.mkdir(exist_ok=True)
        config = directory / 'hyprland.lua'
        base = (args.candidate_base_config if name.startswith('visual-candidate') else args.baseline_base_config if name.startswith('visual-baseline') else None) or r.CONFIG
        gesture_capture = ('local gesture=hl.gesture\nhl.gesture=function(spec) if spec.fingers==3 and spec.direction=="swipe" then test_swipe=spec.action end return gesture(spec) end\n'
                           if args.normal_pan_tests else '')
        config.write_text('local on=hl.on\nhl.on=function(event,cb) if event~="hyprland.start" then return on(event,cb) end end\n'
                          + gesture_capture + 'dofile(' + json.dumps(str(base.resolve())) + ')\nhl.on=on\nhl.config({misc={disable_splash_rendering=true}})\n'
                          + f'hl.monitor({{output="WAYLAND-1",mode="{width}x{height}@120",scale={args.scale}}})\n')
        extra = args.candidate_config if name.startswith('visual-candidate') else args.baseline_config if name.startswith('visual-baseline') else None
        if extra:
            with config.open('a') as out:
                out.write('dofile(' + json.dumps(str(extra.resolve())) + ')\n')
        (directory / 'canvas-state.lua').write_bytes(r.CONFIG.with_name('canvas-state.lua').read_bytes())
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / name))
        listener.listen(16)
        listeners.append(listener)
        child_env = dict(env, XDG_STATE_HOME=str(directory / 'state'), XDG_CONFIG_HOME=str(directory / 'config'), WAYLAND_DISPLAY=display, WAYLAND_DEBUG='client')
        before = set((runtime / 'hypr').glob('*')) if (runtime / 'hypr').exists() else set()
        child = launch([str(binary), '--socket', name, '--wayland-fd', str(listener.fileno()), '--config', str(config)], child_env,
                       directory / 'compositor.log', pass_fds=(listener.fileno(),))
        instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if p not in before and (p / '.socket.sock').exists()), None), [child])
        ctl = lambda command: r.ipc(instance, command)
        assert not ctl('configerrors').strip(), ctl('configerrors')
        r.wait(lambda: any(m['width'] > 0 for m in json.loads(ctl('j/monitors'))), [child])
        return child, ctl, dict(child_env, WAYLAND_DISPLAY=name, GDK_BACKEND='wayland', HYPRLAND_INSTANCE_SIGNATURE=instance.name)
    try:
        assert live('eval ' + rule + '=hl.window_rule({name="' + rule + '",match={class="^aquamarine$"},workspace="special:' + rule + ' silent",float=true,no_initial_focus=true,no_focus=true})').strip() == 'ok'
        parent, ctl, parent_env = compositor(args.baseline, args.output / 'parent', str(args.parent_instance.parent.parent / live_display), 'visual-parent')
        assert ctl(f'eval hl.monitor({{output="HEADLESS-1",mode="{width}x{height}@120",position="0x0",scale=1}})').strip() == 'ok'
        assert ctl('output create headless HEADLESS-1').strip() == 'ok'
        r.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [parent])
        assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
        r.wait(lambda: (monitors := json.loads(ctl('j/monitors'))) and all(m['name'] == 'HEADLESS-1' and m['width'] == width and m['height'] == height for m in monitors), [parent])
        result['private_parent_monitors'] = json.loads(ctl('j/monitors'))
        assert ctl(f'eval hl.window_rule({{name="visual-child",match={{class="^aquamarine$"}},float=true,size="{width} {height}",no_initial_focus=true,no_focus=true,render_unfocused=true}})').strip() == 'ok'
        control = args.baseline
        variants = [('candidate', args.candidate)] if args.candidate_only else [('baseline', control), ('candidate', args.candidate), ('baseline-repeat', control)]
        for name, binary in variants:
            directory = args.output / name
            child, child_ctl, appenv = compositor(binary, directory, 'visual-parent', 'visual-' + name)
            dispatch = lambda action: child_ctl('dispatch hl.dsp.layout(' + json.dumps(action) + ')')
            bg = launch(['swaybg', '-i', str(args.wallpaper.resolve()), '-m', 'fill'] if args.wallpaper else ['swaybg', '-c', '#263344'], appenv, directory / 'wallpaper.log')
            clients = []
            for n in range(4):
                process = launch([sys.executable, str(Path(__file__).resolve()), '--client', str(directory / f'app{n}'), str(n)], appenv, directory / f'app{n}.log')
                clients.append(process)
                r.wait(lambda: len(json.loads(child_ctl('j/clients'))) == n + 1 and (directory / f'app{n}/size').exists(), [child, process])
                time.sleep(.3)
            windows = json.loads(child_ctl('j/clients'))
            for window in reversed(windows[-2:]):
                assert child_ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + window['address']) + '})').strip() == 'ok'
                assert dispatch('move j').strip() == 'ok'
                time.sleep(.4)
            assert child_ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + windows[0]['address']) + '})').strip() == 'ok'
            time.sleep(16)
            def geometry():
                return sorted((w['title'], w['at'], w['size'], w['floating'], w['workspace']['name']) for w in json.loads(child_ctl('j/clients')))
            initial = geometry()
            assert len({g[1][1] for g in initial}) == 2 and all(not g[3] for g in initial)
            run = {'name': name, 'binary': r.sha(binary), 'initial_geometry': initial, 'trials': [], 'keys': [], 'captures': [],
                   'profile': Path('/sys/firmware/acpi/platform_profile').read_text().strip(),
                   'ac': Path('/sys/class/power_supply/ACAD/online').read_text().strip()}
            run['monitor'] = json.loads(child_ctl('j/monitors'))[0]
            result['runs'].append(run)
            def keycheck(label):
                focused = json.loads(child_ctl('j/activewindow'))
                folder = directory / f'app{[p.pid for p in clients].index(focused["pid"])}'
                keyfile = folder / 'keys'
                before = keyfile.read_text().splitlines() if keyfile.exists() else []
                subprocess.run(['wtype', 'x'], env=appenv, check=True, timeout=5, capture_output=True)
                r.wait(lambda: keyfile.exists() and len(keyfile.read_text().splitlines()) == len(before) + 1, [child])
                assert keyfile.read_text().splitlines()[-1] == '120'
                run['keys'].append({'mode': label, 'title': focused['title'], 'received': 'x'})
            def capture(label):
                path = directory / (label + '.png')
                subprocess.run(['grim', '-o', 'WAYLAND-1', str(path)], env=appenv, check=True, capture_output=True, timeout=10)
                run['captures'].append({'label': label, 'time': time.monotonic(), 'sha256': r.sha(path)})
            if args.minimap_smoke:
                assert args.candidate_only and args.scale == 1
                keycheck('normal')
                assert dispatch('focus l').strip() == 'ok'
                time.sleep(1.1)
                keycheck('normal-focus')
                assert run['keys'][-1]['title'] == 'Notes / visual language'
                assert dispatch('overview').strip() == 'ok'
                time.sleep(1.1)
                def image(label):
                    capture(label)
                    return subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / (label + '.png')), '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=5)
                high = image('overview-hud')
                reply = child_ctl('eval hl.config({experimental={canvas_panel_opacity=0.4}})')
                assert reply.strip() == 'ok', reply
                time.sleep(.3)
                low = image('overview-low-opacity')
                def changed(x, y, w, h):
                    return sum(high[n:n+3] != low[n:n+3] for row in range(y,y+h) for col in range(x,x+w) for n in [(row*width+col)*3])
                hud = changed(24,24,600,50)
                minimap = changed(width-264,height-174,240,150)
                assert hud > 500 and minimap == 0, (hud, minimap)
                orange = sum(high[n]>225 and 80<high[n+1]<140 and 15<high[n+2]<45 for n in range(0,len(high),3))
                assert orange > 100, orange
                keycheck('overview')
                assert dispatch('focus j').strip() == 'ok'
                time.sleep(1.1)
                keycheck('overview-focus')
                assert run['keys'][-1]['title'] == 'Browser / project'
                assert dispatch('pan-end').strip() == 'ok'
                time.sleep(1.1)
                keycheck('returned')
                capture('returned')
                assert geometry() == initial
                assert not child_ctl('configerrors').strip(), child_ctl('configerrors')
                run['minimap_smoke'] = {'hud_changed_pixels':hud,'minimap_changed_pixels':minimap,'selection_orange_pixels':orange,'unchanged_tiled_geometry':True}
                run['passed'] = True
                continue
            if args.framing_smoke:
                assert args.candidate_only and args.scale == 1
                boxes = {w['title'].split(' / ')[0]: w for w in json.loads(child_ctl('j/clients'))}
                gaps = [boxes['Notes']['at'][0]-boxes['Editor']['at'][0]-boxes['Editor']['size'][0], boxes['Terminal']['at'][1]-boxes['Editor']['at'][1]-boxes['Editor']['size'][1]]
                assert gaps == [52, 52], gaps
                dispatch('camera-center')
                time.sleep(1)
                def body_bounds(label):
                    capture(label)
                    row = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / (label + '.png')), '-vf', f'crop={width}:1:0:{height//2}', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=5)
                    center = row[width//2*3:width//2*3+3]
                    left = right = width//2
                    matches = lambda x: max(abs(a-b) for a,b in zip(row[x*3:x*3+3], center)) < 8
                    while left > 0 and matches(left-1): left -= 1
                    while right < width-1 and matches(right+1): right += 1
                    return [left, right]
                normal = body_bounds('framing-normal')
                with subprocess.Popen([str(args.key_sender), '--hold', '2500', 'super+tab'], env=appenv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as sender:
                    time.sleep(1)
                    capture('framing-lens')
                    assert child_ctl('eval hl.config({experimental={canvas_lens=false}})').strip() == 'ok'
                    time.sleep(.2)
                    overview = body_bounds('framing-overview')
                    ratio = (overview[1]-overview[0]) / (normal[1]-normal[0])
                    assert abs(ratio-.72) < .01 and abs(sum(overview)-sum(normal)) < 4, (normal, overview, ratio)
                    sender.wait(timeout=4)
                time.sleep(1)
                assert body_bounds('framing-return') == normal
                dispatch('pan-begin')
                dispatch('pan 100 0')
                time.sleep(.5)
                panned = body_bounds('framing-normal-pan')
                assert abs((panned[1]-panned[0])-(normal[1]-normal[0])) <= 4
                dispatch('pan-end')
                time.sleep(1)
                dispatch('overview')
                time.sleep(1)
                dispatch('focus l')
                time.sleep(1)
                keycheck('framing-overview-focus')
                assert run['keys'][-1]['title'] == 'Notes / visual language'
                dispatch('pan-end')
                time.sleep(1)
                keycheck('framing-return-focus')
                assert geometry() == initial
                for _ in range(20): dispatch('resize l')
                time.sleep(1)
                capture('framing-oversized')
                title = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / 'framing-oversized.png'), '-vf', 'crop=200:60:0:30', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=5)
                assert sum(min(title[i:i+3]) > 180 for i in range(0, len(title), 3)) > 20, 'oversized title moved offscreen'
                assert not child_ctl('configerrors').strip()
                run['framing'] = {'normal': normal, 'overview': overview, 'ratio': ratio, 'normal_pan': panned, 'client_box_gaps': gaps}
                run['passed'] = True
                continue
            if args.normal_pan_tests:
                from canvas_interaction_test import run_interaction
                run['normal_pan'] = run_interaction(args, directory, child_ctl, appenv, capture, keycheck)
            if args.backdrop_tests:
                assert args.candidate_only and args.scale == 1
                marker, qml = directory / 'background-state', directory / 'background.qml'
                marker.write_text('#336699')
                qml.write_text('import QtQuick\nimport Quickshell\nimport Quickshell.Wayland\nimport Quickshell.Io\n'
                    'ShellRoot { PanelWindow { id: panel; property string tint: "#336699"; property bool pattern: false; '
                    'anchors { left: true; right: true; top: true; bottom: true } exclusionMode: ExclusionMode.Ignore; '
                    'WlrLayershell.layer: WlrLayer.Background; WlrLayershell.namespace: "canvas-cache-test"; color: tint; '
                    'FileView { path: ' + json.dumps(str(marker.resolve())) + '; watchChanges: true; onFileChanged: reload(); '
                    'onLoaded: { const parts=text().trim().split(","); panel.tint=parts[0]; panel.pattern=parts.length>1; } } '
                    'Repeater { model: panel.pattern ? 20 : 0; Rectangle { required property int index; '
                    'x: index*panel.width/20; width: panel.width/20; height: panel.height; color: index%2 ? "#eedd33" : panel.tint } } } }\n')
                wallpaper = launch(['qs', '-p', str(qml.resolve())], dict(appenv, QT_QPA_PLATFORM='wayland'), directory / 'background-client.log')
                r.wait(lambda: 'canvas-cache-test' in child_ctl('j/layers'), [wallpaper, child])
                def configure(values):
                    assert child_ctl('eval hl.config({experimental={' + values + '}})').strip() == 'ok'
                    time.sleep(1)
                def pixels(label):
                    capture(label)
                    return subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / (label + '.png')),
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=10)
                def pixel(image, x, y):
                    at = (y * width + x) * 3
                    return list(image[at:at+3])
                configure('canvas_lens=false,canvas_grid_opacity=0,canvas_backdrop_dim=0,canvas_backdrop_blur=0,canvas_parallax_strength=0,canvas_parallax_depth=0')
                dispatch('overview')
                time.sleep(1)
                first = pixel(pixels('cache-blue'), 8, 8)
                assert max(abs(a-b) for a,b in zip(first, (51,102,153))) <= 1, first
                marker.write_text('#669933')
                time.sleep(1)
                second = pixel(pixels('cache-green'), 8, 8)
                assert max(abs(a-b) for a,b in zip(second, (102,153,51))) <= 1, ('same-layer commit remained stale', second)
                marker.write_text('#336699,pattern')
                time.sleep(1)
                sharp = pixels('cache-pattern-sharp')
                configure('canvas_backdrop_blur=0.7')
                blurred = pixels('cache-pattern-blurred')
                assert sum(abs(a-b) for a,b in zip(sharp[:width*24*3], blurred[:width*24*3])) > 10000, 'blur control did not change the wallpaper'
                capture('cache-pattern-repeat')
                assert r.sha(directory / 'cache-pattern-repeat.png') == r.sha(directory / 'cache-pattern-blurred.png'), 'static cached frame changed'
                marker.write_text('#663399,pattern')
                time.sleep(1)
                updated_blur = pixels('cache-blurred-update')
                assert sum(abs(a-b) for a,b in zip(blurred[:width*24*3], updated_blur[:width*24*3])) > 10000, 'blurred wallpaper ignored same-layer damage'
                marker.write_text('#336699,pattern')
                time.sleep(1)
                dispatch('pan-end')
                for process in reversed(clients[1:]):
                    stop(process)
                clients = clients[:1]
                time.sleep(1)
                dispatch('resize j')
                dispatch('resize j')
                time.sleep(1)
                dispatch('camera-center')
                configure('canvas_lens=true,canvas_backdrop_blur=0')
                single = json.loads(child_ctl('j/clients'))[0]
                assert all(v == 0 for v in run['monitor']['reserved'])
                assert single['size'][0] + 96 < width and single['size'][1] + 96 < height, single
                normal = pixel(pixels('one-window-normal'), 8, 8)
                dispatch('overview')
                time.sleep(1)
                overview = pixel(pixels('one-window-overview'), 8, 8)
                assert max(normal) > 40 and max(overview) <= 2, ('effects must reveal when fit zoom is 1', normal, overview)
                configure('canvas_lens=false,canvas_parallax_strength=0.5')
                camera = single['at'][0] + single['size'][0] / 2 - width / 2
                dispatch('pan-begin')
                dispatch(f'pan {-width-camera} 0')
                time.sleep(1)
                mirrored = pixels('cache-mirrored')
                pairs = [[pixel(mirrored, width//2-d, height//2), pixel(mirrored, width//2+d-1, height//2)] for d in (20,90)]
                assert all(max(abs(a-b) for a,b in zip(*pair)) <= 2 for pair in pairs), ('alternating tiles were not mirrored', pairs)
                assert sum(abs(a-b) for a,b in zip(pairs[0][0],pairs[1][0])) > 80, ('mirror test lacks pattern contrast', pairs)
                run['backdrop'] = {'passed': True, 'same_surface_commit': [first, second], 'fit_zoom_one': [normal, overview],
                    'mirror_pairs': pairs, 'fixture_sha256': r.sha(qml)}
                assert not child_ctl('configerrors').strip()
                run['passed'] = True
                for process in reversed(clients):
                    stop(process)
                stop(wallpaper)
                stop(bg)
                stop(child)
                continue
            if args.floating_tests:
                from canvas_floating_test import run_floating
                run['floating'] = run_floating(args, directory, child_ctl, appenv, dispatch, capture)
                run['passed'] = True
                for process in reversed(clients):
                    stop(process)
                stop(bg)
                stop(child)
                continue
            if args.effect_tests:
                from canvas_effects_test import run_effects
                run['effects'] = run_effects(args, directory, child, child_ctl, dispatch, capture, r.counters)
                assert geometry() == initial
                assert run['profile'] == Path('/sys/firmware/acpi/platform_profile').read_text().strip()
                assert run['ac'] == Path('/sys/class/power_supply/ACAD/online').read_text().strip()
                run['passed'] = True
                for process in reversed(clients):
                    stop(process)
                stop(bg)
                stop(child)
                continue
            if args.tuning_tests:
                from canvas_tuning_test import run_palette
                run['palette'] = run_palette(args, directory, child, child_ctl, appenv, dispatch, capture, keycheck, r)
                assert geometry() == initial
                assert not child_ctl('configerrors').strip()
                run['passed'] = True
                for process in reversed(clients):
                    stop(process)
                stop(bg)
                stop(child)
                (directory / 'compositor.log').rename(directory / 'compositor-first.log')
                child, restarted_ctl, restarted_env = compositor(binary, directory, 'visual-parent', 'visual-candidate-restart')
                state = subprocess.run([sys.executable, str(ROOT / 'tuning/tune.py'), 'state'], env=restarted_env,
                                       text=True, capture_output=True, check=True, timeout=10)
                assert json.loads(state.stdout)['rows'] == run['palette']['saved']['rows'], state.stdout
                assert not restarted_ctl('configerrors').strip()
                run['palette']['restart_persistence_passed'] = True
                stop(child)
                continue
            if args.focus_sequences:
                run['focus_scenarios'] = []
                expected = ['Notes / visual language', 'Browser / project', 'Terminal / build', 'Editor / canvas.cpp']
                editor = next(w for w in windows if w['title'] == expected[-1])
                source = (directory / 'compositor.log').read_text()
                surface = re.search(r'get_xdg_surface\([^\n]*wl_surface[#@](\d+)\)', source)[1]
                for mode, interval in [('normal', 1000), ('normal-burst', 80), ('overview', 1000), ('overview-burst', 80), ('normal-interrupted', 1000)]:
                    scenario = {'mode': mode, 'interval_ms': interval, 'trials': []}
                    run['focus_scenarios'].append(scenario)
                    for trial in range(2 if mode == 'normal-interrupted' else args.repeats + 1):
                        dispatch('pan-end')
                        child_ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + editor['address']) + '})')
                        dispatch('camera-center')
                        time.sleep(1.1)
                        if mode.startswith('overview'):
                            dispatch('overview')
                            time.sleep(1.1)
                        if trial == 0:
                            recorder = launch(['wf-recorder', '--no-dmabuf', '-o', 'WAYLAND-1', '-c', 'ffv1', '-x', 'bgr0', '-f', str(directory / (mode + '.mkv'))], appenv, directory / (mode + '-recording.log'))
                            time.sleep(.4)
                            assert recorder.poll() is None
                        command = [str(args.key_sender), str(interval)]
                        offset = (directory / 'compositor.log').stat().st_size
                        before = r.counters(child.pid)
                        sender = launch(command, appenv, directory / f'{mode}-{trial}-keys.log')
                        changes = []
                        interrupted = False
                        previous = expected[-1]
                        while sender.poll() is None:
                            focused = json.loads(child_ctl('j/activewindow'))['title']
                            if focused != previous:
                                changes.append({'time': time.monotonic(), 'title': focused})
                                previous = focused
                            if mode == 'normal-interrupted' and changes and not interrupted:
                                dispatch('pan-begin')
                                dispatch('pan 12 0')
                                dispatch('pan-end')
                                interrupted = True
                            time.sleep(.01)
                        assert sender.returncode == 0
                        processes.remove(sender)
                        time.sleep(1)
                        after = r.counters(child.pid)
                        tail = (directory / 'compositor.log').read_bytes()[offset:].decode(errors='replace')
                        stamps = re.findall(r'\[(\d+:\d+:[\d.]+)\][^\n]*-> wl_surface[#@]' + surface + r'\.commit\(', tail)
                        times = [sum(float(v) * u for v, u in zip(s.split(':'), (3600000,60000,1000))) for s in stamps]
                        keys = [float(stamp) for stamp in re.findall(r'^KEY ([\d.]+) [ljhk]$', (directory / f'{mode}-{trial}-keys.log').read_text(), re.M)]
                        assert len(keys) == 4, keys
                        anchor = time.monotonic()
                        wall = datetime.now(timezone.utc)
                        wall_ms = (wall.hour * 3600 + wall.minute * 60 + wall.second) * 1000 + wall.microsecond / 1000
                        submitted = [anchor + ((stamp-wall_ms+43200000) % 86400000-43200000)/1000 for stamp in times]
                        gaps = [(b-a)*1000 for a,b in zip(submitted,submitted[1:]) if any(key <= a < key + .2 for key in keys)]
                        assert len(gaps) > 10
                        row = {'trial': trial, 'recorded': trial == 0, 'seconds': after['time']-before['time'], 'gpu_ms': (after['gfx_ns']-before['gfx_ns'])/1e6,
                               'cpu_ms': (after['cpu_ticks']-before['cpu_ticks'])/os.sysconf('SC_CLK_TCK')*1000, 'frames': len(times),
                               'active_gap_p95_ms': sorted(gaps)[math.ceil(.95*len(gaps))-1], 'active_gap_max_ms': max(gaps), 'focus_changes': changes, 'key_times': keys,
                               'focus_order_matches': [change['title'] for change in changes] == expected}
                        scenario['trials'].append(row)
                        if trial == 0:
                            recorder.send_signal(signal.SIGINT)
                            subprocess.run(['grim', '-o', 'WAYLAND-1', str(directory / (mode + '-settled.png'))], env=appenv, check=True, capture_output=True, timeout=10)
                            recorder.wait(timeout=15)
                            processes.remove(recorder)
                            assert recorder.returncode == 0
                            ready = [(float(stamp), int(hi) * 4294967296 + int(lo) + int(ns) / 1e9) for stamp,hi,lo,ns in re.findall(r'\[\s*([\d.]+)\].*\.ready\((\d+), (\d+), (\d+)\)', (directory / (mode + '-recording.log')).read_text())]
                            scenario['key_times'] = keys
                            scenario['video_frames'] = [when for stamp,when in ready]
                            pts = json.loads(subprocess.check_output([str(Path(args.ffmpeg).with_name('ffprobe')), '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'json', str(directory / (mode + '.mkv'))]))['frames']
                            assert len(ready) >= len(pts) and all(abs(float(frame['pts_time']) - (ready[n][1] - ready[0][1])) < .003 for n,frame in enumerate(pts))
                            for label, delay in [('entry', .025), ('mid', .075), ('travel', .15), ('tail', .3), ('late', .6)]:
                                target = scenario['key_times'][0] + delay
                                index = min(range(len(ready)), key=lambda n: abs(ready[n][1] - target))
                                subprocess.run([args.ffmpeg, '-v', 'error', '-y', '-i', str(directory / (mode + '.mkv')), '-vf', f'select=eq(n\\,{index})', '-frames:v', '1', str(directory / f'{mode}-{label}.png')], check=True, capture_output=True, timeout=15)
                            keycheck(mode)
                        assert geometry() == initial, 'focus transition moved tiled geometry'
                        print(name, mode, json.dumps(row), flush=True)
                assert all(t['focus_order_matches'] for s in run['focus_scenarios'] for t in s['trials']), 'focus-key sequence regressed'
                assert not child_ctl('configerrors').strip()
                assert run['profile'] == Path('/sys/firmware/acpi/platform_profile').read_text().strip()
                assert run['ac'] == Path('/sys/class/power_supply/ACAD/online').read_text().strip()
                run['passed'] = True
                for process in reversed(clients):
                    stop(process)
                stop(bg)
                stop(child)
                continue
            if args.lens_tests:
                from canvas_lens_test import run_lens
                run['lens_inputs'] = run_lens(args, directory, child_ctl, appenv, capture, keycheck, name == 'candidate' or args.baseline_lens, name == 'candidate' and args.fit_overview)
            keycheck('normal')
            capture('normal')
            recorder = launch(['wf-recorder', '--no-dmabuf', '-o', 'WAYLAND-1', '-c', 'ffv1', '-x', 'bgr0', '-f', str(directory / 'transition.mkv')], appenv, directory / 'recording.log')
            time.sleep(.7)
            assert recorder.poll() is None
            run['entry_time'] = time.monotonic()
            dispatch('overview')
            time.sleep(1)
            capture('settled')
            keycheck('overview')
            run['exit_time'] = time.monotonic()
            dispatch('pan-end')
            time.sleep(.12)
            capture('exit-delayed')
            time.sleep(1)
            capture('returned')
            keycheck('returned')
            recorder.send_signal(signal.SIGINT)
            subprocess.run(['grim', '-o', 'WAYLAND-1', str(directory / 'wake.png')], env=appenv, check=True, capture_output=True, timeout=10)
            recorder.wait(timeout=15)
            processes.remove(recorder)
            assert recorder.returncode == 0
            ready = [int(hi) * 4294967296 + int(lo) + int(ns) / 1e9 for hi,lo,ns in re.findall(r'\.ready\((\d+), (\d+), (\d+)\)', (directory / 'recording.log').read_text())]
            pts = json.loads(subprocess.check_output([str(Path(args.ffmpeg).with_name('ffprobe')), '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'json', str(directory / 'transition.mkv')]))['frames']
            assert len(ready) >= len(pts) and all(abs(float(frame['pts_time']) - (ready[n] - ready[0])) < .003 for n,frame in enumerate(pts)), 'video frame timing is not aligned with screencopy'
            for label, target in [('entry', run['entry_time'] + .025), ('mid', run['entry_time'] + .075), ('exit', run['exit_time'] + .075)]:
                index = min(range(len(pts)), key=lambda n: abs(ready[n] - target))
                assert abs(ready[index] - target) < .025, 'transition capture missed requested phase'
                path = directory / (label + '.png')
                subprocess.run([args.ffmpeg, '-v', 'error', '-y', '-i', str(directory / 'transition.mkv'), '-vf', f'select=eq(n\\,{index})', '-frames:v', '1', str(path)], check=True, capture_output=True, timeout=15)
                run['captures'].append({'label': label, 'requested_time': target, 'actual_time': ready[index], 'frame': index, 'sha256': r.sha(path)})
            assert r.sha(directory / 'normal.png') == r.sha(directory / 'returned.png'), 'exit did not restore the normal scene'
            assert geometry() == initial, 'overview changed tiled geometry'
            for direction in ('l', 'j', 'h', 'k'):
                dispatch('focus ' + direction)
                time.sleep(.6)
                keycheck('focus-' + direction)
            assert [k['title'] for k in run['keys'][-7:]] == ['Editor / canvas.cpp'] * 3 + ['Notes / visual language', 'Browser / project', 'Terminal / build', 'Editor / canvas.cpp']
            assert geometry() == initial, 'navigation changed tiled geometry'
            source = (directory / 'compositor.log').read_text()
            surface = re.search(r'get_xdg_surface\([^\n]*wl_surface[#@](\d+)\)', source)[1]
            for mode in ('normal', 'overview'):
                dispatch('pan-end')
                time.sleep(1)
                if mode == 'overview':
                    dispatch('overview')
                time.sleep(1)
                for trial in range(args.repeats):
                    path = directory / 'compositor.log'
                    offset = path.stat().st_size
                    before = r.counters(child.pid)
                    dispatch('pan-begin')
                    start, previous = time.monotonic(), 0.0
                    lateness = []
                    for n in range(120):
                        due = start + n / 60
                        time.sleep(max(0, due - time.monotonic()))
                        lateness.append(time.monotonic() - due)
                        x = 80 * math.sin(2 * math.pi * (n + 1) / 120)
                        assert dispatch(f'pan {x - previous:.6f} 0').strip() == 'ok'
                        previous = x
                    time.sleep(.3)
                    after = r.counters(child.pid)
                    tail = path.read_bytes()[offset:].decode(errors='replace')
                    stamps = re.findall(r'\[(\d+:\d+:[\d.]+)\][^\n]*-> wl_surface[#@]' + surface + r'\.commit\(', tail)
                    times = [sum(float(v) * u for v, u in zip(s.split(':'), (3600000,60000,1000))) for s in stamps]
                    gaps = [(b-a) % 86400000 for a,b in zip(times,times[1:])]
                    assert len(times) > 60, 'not enough submitted frames for a rendering comparison'
                    row = {'mode': mode, 'trial': trial, 'seconds': after['time']-before['time'], 'gpu_ms': (after['gfx_ns']-before['gfx_ns'])/1e6,
                           'cpu_ms': (after['cpu_ticks']-before['cpu_ticks'])/os.sysconf('SC_CLK_TCK')*1000, 'frames': len(times),
                           'gap_p95_ms': sorted(gaps)[math.ceil(.95*len(gaps))-1], 'input_max_lateness_ms': max(lateness)*1000}
                    run['trials'].append(row)
                    print(name, json.dumps(row), flush=True)
                    time.sleep(.4)
            assert geometry() == initial
            assert run['profile'] == Path('/sys/firmware/acpi/platform_profile').read_text().strip()
            assert run['ac'] == Path('/sys/class/power_supply/ACAD/online').read_text().strip()
            assert run['initial_geometry'] == result['runs'][0]['initial_geometry']
            assert not child_ctl('configerrors').strip()
            run['passed'] = True
            for process in reversed(clients):
                stop(process)
            stop(bg)
            stop(child)
        assert all(r.sha(path) == digest for path,digest in input_hashes.items())
        result['passed'] = True
    finally:
        for process in list(reversed(processes)):
            try:
                stop(process)
            except Exception as error:
                result['cleanup_errors'].append(str(error))
        for listener in listeners:
            listener.close()
        for log in logs:
            log.close()
        assert live('eval ' + rule + ':set_enabled(false);' + rule + '=nil').strip() == 'ok'
        result['live_binary_unchanged'] = r.sha(f'/proc/{live_pid}/exe') == live_hash
        result['passed'] = result['passed'] and result['live_binary_unchanged'] and not result['cleanup_errors']
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(args.output / 'result.json', flush=True)


if __name__ == '__main__':
    if sys.argv[1] == '--client':
        client(Path(sys.argv[2]), int(sys.argv[3]))
    else:
        main()
