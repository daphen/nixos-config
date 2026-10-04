#!/usr/bin/env python3
"""Compare size-request delivery and final client redraw under a resize burst."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rendering', HERE / 'test-canvas-rendering.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
CLIENT = HERE / 'regression-archive/hyprland-canvas-resize/client.py'
CONFIG = HERE.parents[1] / 'dotfiles/hyprland/.config/hypr/hyprland.lua'


def run(binary, parent_instance, output, visible, siblings, scale):
    output.mkdir(parents=True, exist_ok=False)
    runtime = Path(tempfile.mkdtemp(prefix='cp-'))
    parent_pid, parent_display = (parent_instance / 'hyprland.lock').read_text().splitlines()
    parent = lambda command: helpers.ipc(parent_instance, command)
    rule = f'canvas_pacing_{os.getpid()}'
    workspace = json.loads(parent('j/activeworkspace'))['address'] if visible else 'special:' + rule
    wrapper = output / 'hyprland.lua'
    wrapper.write_text('local on=hl.on\nhl.on=function(e,cb) if e~="hyprland.start" then return on(e,cb) end end\n'
                       + 'dofile(' + json.dumps(str(CONFIG)) + ')\nhl.on=on\n'
                       + 'hl.config({misc={disable_splash_rendering=true,disable_watchdog_warning=true,disable_hyprland_guiutils_check=true}})\n'
                       + 'hl.monitor({output="WAYLAND-1",mode="preferred",scale=' + str(scale) + '})\n')
    (output / 'canvas-state.lua').write_bytes(CONFIG.with_name('canvas-state.lua').read_bytes())
    env = os.environ.copy()
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NOTIFY_SOCKET', 'SWAYSOCK', 'NIRI_SOCKET'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(output / 'config'),
               XDG_STATE_HOME=str(output / 'state'), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation')
    processes, logs, samples = [], [], []
    listener, rule_added = None, False
    result = {'binary_sha256': helpers.sha(binary), 'runner_sha256': helpers.sha(__file__),
              'fixture_sha256': helpers.sha(CLIENT), 'config_sha256': helpers.sha(CONFIG),
              'parent_sha256': helpers.sha(f'/proc/{parent_pid}/exe'), 'visible': visible, 'siblings': siblings, 'samples': samples, 'passed': False}

    def launch(command, environment, name, **kwargs):
        log = (output / name).open('w')
        logs.append(log)
        proc = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        processes.append(proc)
        return proc

    try:
        assert parent('eval ' + rule + '=hl.window_rule({name=' + json.dumps(rule)
                      + ',match={class="^aquamarine$"},workspace=' + json.dumps(workspace + ' silent')
                      + ',float=true,size="900 600",no_initial_focus=true,no_focus=true,render_unfocused=true})').strip() == 'ok'
        rule_added = True
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / 'pacing-test'))
        listener.listen(16)
        childenv = dict(env, WAYLAND_DISPLAY=str(parent_instance.parent.parent / parent_display),
                        AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none', WAYLAND_DEBUG='server')
        child = launch([str(binary), '--socket', 'pacing-test', '--wayland-fd', str(listener.fileno()),
                        '--config', str(wrapper)], childenv, 'compositor.log', pass_fds=(listener.fileno(),))
        instance = helpers.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None), [child])
        ctl = lambda command: helpers.ipc(instance, command)
        outer = helpers.wait(lambda: next((w for w in json.loads(parent('j/clients')) if w['pid'] == child.pid), None), [child])
        assert outer['floating'] and outer['workspace']['address'] == workspace
        assert json.loads(parent('j/activewindow')).get('pid') != child.pid
        assert not ctl('configerrors').strip()
        result['monitor'] = json.loads(ctl('j/monitors'))[0]
        assert abs(result['monitor']['scale'] - scale) < .001
        appenv = dict(env, WAYLAND_DISPLAY='pacing-test', GDK_BACKEND='wayland', RESIZE_NO_REPAINT='1')

        def dispatch(action):
            assert ctl('dispatch hl.dsp.layout(' + json.dumps(action) + ')').strip() == 'ok'

        def capture(folder, number):
            path = folder / f'frame-{number:03}.ppm'
            subprocess.run(['grim', '-t', 'ppm', str(path)], env=appenv, check=True, timeout=5)
            magic, dimensions, maximum, pixels = path.read_bytes().split(b'\n', 3)
            assert magic == b'P6' and maximum == b'255'
            width, height = map(int, dimensions.split())
            row = pixels[(height // 2) * width * 3:(height // 2 + 1) * width * 3]
            body = [x for x in range(width) if (row[x*3+1] < 15 and row[x*3]+row[x*3+2] > 100)
                    or min(row[x*3:x*3+3]) > 120]
            spans = []
            for x in body:
                if not spans or x > spans[-1][1] + 8:
                    spans.append([x, x])
                else:
                    spans[-1][1] = x
            active = next((span for span in spans if span[0] <= width // 2 <= span[1]), None)
            center = (width // 2) * 3
            return {'time': time.monotonic(), 'width': active[1]-active[0]+1 if active else 0,
                    'gap': spans[1][0]-spans[0][1]-1 if len(spans) == 2 else None,
                    'color': list(row[center:center+3])}

        for delay in (0, .15, .5):
            for trial in range(3):
                folder = output / f'delay-{delay}-trial-{trial}'
                folder.mkdir()
                sibling = None
                if siblings:
                    sibling_dir = folder / 'sibling'
                    sibling_dir.mkdir()
                    sibling = launch(['python3', str(CLIENT), str(sibling_dir)], dict(appenv, RESIZE_DELAY='0'), folder.name + '-sibling.log')
                    helpers.wait(lambda: (sibling_dir / 'client-size').exists(), [child, sibling])
                app = launch(['python3', str(CLIENT), str(folder)], dict(appenv, RESIZE_DELAY=str(delay)), folder.name + '.log')
                primary = lambda: next((w for w in json.loads(ctl('j/clients')) if w['pid'] == app.pid), None)
                helpers.wait(lambda: (folder / 'client-size').exists() and primary(), [child, app])
                assert ctl('dispatch hl.dsp.focus({window="address:' + primary()['address'] + '"})').strip() == 'ok'
                dispatch('center')
                time.sleep(1)
                initial = tuple(map(int, (folder / 'client-size').read_text().split()))
                assert len(initial) == 2 and initial == tuple(primary()['size'])
                (folder / 'arm').write_text(f'{initial[0]} {initial[1]}')
                before = capture(folder, 0) if trial < 2 or siblings else None
                offset = (output / 'compositor.log').stat().st_size
                start_wall = time.time()
                start = time.monotonic()
                dispatch('resize h' if trial == 1 else 'resize l')
                if delay:
                    helpers.wait(lambda: (folder / 'delayed').exists(), [child, app])
                directions = [] if trial < 2 else ['h', 'l'] * 9 + ['h', 'l', 'l']
                for direction in directions:
                    dispatch('resize ' + direction)
                    time.sleep(.005)
                input_end = time.monotonic()
                frames = []
                if trial < 2 or siblings:
                    while time.monotonic() - start < .9:
                        frames.append(capture(folder, len(frames) + 1))
                expected = tuple(primary()['size'])
                assert expected != initial

                def client_finished():
                    size = tuple(map(int, (folder / 'client-size').read_text().split()))
                    return size == expected

                helpers.wait(client_finished, [child, app])
                final_draw = start + (folder / 'client-size').stat().st_mtime - start_wall
                time.sleep(.3)
                assert client_finished()
                with (output / 'compositor.log').open('rb') as log:
                    log.seek(offset)
                    protocol = log.read().decode(errors='replace')
                sizes = [list(map(int, size)) for size in re.findall(r'-> xdg_toplevel[#@]\d+\.configure\((\d+), (\d+),', protocol)]
                assert sizes and sizes[-1] == list(expected)
                visual = None
                if frames:
                    for frame in frames:
                        frame['after_request_ms'] = (frame.pop('time') - start) * 1000
                    waiting = [f for f in frames if f['after_request_ms'] < delay * 1000]
                    assert all(abs(f['width'] - before['width']) <= 1 for f in waiting if f['after_request_ms'] < 250), 'window resized before its buffer was ready'
                    green = before['color'][1]
                    mixed = [f for f in frames if f['color'][0] > green + 20 and f['color'][2] > green + 20]
                    energy = before['color'][0] + before['color'][2]
                    assert all(abs(f['color'][1] - green) <= 1 and abs(f['color'][0] + f['color'][2] - energy) <= 2 for f in mixed), 'crossfade changed opacity or color energy'
                    if delay < .3:
                        if trial < 2:
                            assert mixed, 'no old/new crossfade was captured'
                    elif trial < 2:
                        assert any(f['width'] != before['width'] for f in waiting), 'stalled client never released the held geometry'
                    assert frames[-1]['color'][0] > frames[-1]['color'][2] + 100, 'final content is not the new buffer'
                    visual = {'before': before, 'frames': frames, 'mixed_frames': len(mixed)}
                    if siblings:
                        gaps = [before['gap']] + [f['gap'] for f in frames]
                        assert all(g is not None for g in gaps), 'both sibling edges must remain visible'
                        visual['gap_range'] = [min(gaps), max(gaps)]
                        assert max(gaps)-min(gaps) <= 2, f'sibling gap changed: {visual["gap_range"]}'
                row = {'delay_seconds': delay, 'trial': trial, 'input_requests': len(directions) + 1, 'configure_events': len(sizes),
                       'visual': visual,
                       'input_duration_ms': (input_end-start)*1000, 'final_draw_after_input_ms': (final_draw-input_end)*1000,
                       'total_to_final_draw_ms': (final_draw-start)*1000,
                       'last_client_draw_ms': ((folder / 'client-size').stat().st_mtime-start_wall)*1000,
                       'initial': initial, 'final': expected, 'configured_sizes': sizes}
                samples.append(row)
                print(json.dumps({k:v for k,v in row.items() if k not in ('configured_sizes', 'visual')}), flush=True)
                if delay == .5 and (trial == 2 or siblings and trial == 1):
                    (folder / 'arm').write_text((folder / 'client-size').read_text())
                    (folder / 'delayed').unlink()
                    dispatch('resize l')
                    helpers.wait(lambda: (folder / 'delayed').exists(), [child, app])
                    if siblings and trial == 1:
                        assert ctl('dispatch hl.dsp.window.move({workspace="2",follow=false,window="address:' + primary()['address'] + '"})').strip() == 'ok'
                        survivor = lambda: next(w for w in json.loads(ctl('j/clients')) if w['pid'] == sibling.pid)
                        helpers.wait(lambda: primary()['workspace']['address'] != survivor()['workspace']['address'], [child, app])
                        assert ctl('dispatch hl.dsp.focus({window="address:' + survivor()['address'] + '"})').strip() == 'ok'
                        dispatch('center')
                        time.sleep(.4)
                        assert abs(capture(folder, 998)['width']-survivor()['size'][0]*scale) <= 2, 'workspace move left a sibling frozen'
                        row['moved_while_waiting'] = True
                app.terminate()
                app.wait(timeout=5)
                helpers.wait(lambda: primary() is None, [child])
                if sibling:
                    time.sleep(.4)
                    dispatch('resize l')
                    time.sleep(.5)
                    settled = capture(folder, 999)
                    remaining = json.loads(ctl('j/clients'))
                    assert len(remaining) == 1 and abs(settled['width']-remaining[0]['size'][0]*scale) <= 2, 'surviving sibling stayed frozen'
                    sibling.terminate()
                    sibling.wait(timeout=5)
                helpers.wait(lambda: not json.loads(ctl('j/clients')), [child])
        time.sleep(.4)
        assert child.poll() is None, 'compositor exited after closing a waiting client'
        assert not ctl('configerrors').strip()
        assert result['config_sha256'] == helpers.sha(CONFIG)
        result['passed'] = True
    finally:
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                    result['passed'] = False
        if listener:
            listener.close()
        if rule_added:
            assert parent('eval ' + rule + ':set_enabled(false);' + rule + '=nil').strip() == 'ok'
        for log in logs:
            log.close()
        assert helpers.sha(f'/proc/{parent_pid}/exe') == result['parent_sha256']
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--visible', action='store_true', help='requires permission to show a non-focusing nested window')
    parser.add_argument('--siblings', action='store_true', help='measure spacing against a second real window')
    parser.add_argument('--scale', type=float, default=1, help='nested output scale')
    args = parser.parse_args()
    run(args.binary.resolve(strict=True), args.parent_instance.resolve(strict=True), args.output.resolve(), args.visible, args.siblings, args.scale)


if __name__ == '__main__':
    main()
