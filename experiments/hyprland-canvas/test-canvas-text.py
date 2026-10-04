#!/usr/bin/env python3
"""Compare Canvas text with floating references at identical Qt client sizes."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rendering', HERE / 'test-canvas-rendering.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expect-stable', action='store_true')
    parser.add_argument('--scale', type=float, choices=(1.5, 1.6666666667), default=1.5)
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    runtime = Path(tempfile.mkdtemp(prefix='canvas-text-'))
    parent_pid, parent_display = (args.parent_instance / 'hyprland.lock').read_text().splitlines()
    parent = lambda command: helpers.ipc(args.parent_instance, command)
    rule = f'canvas_text_test_{os.getpid()}'
    workspace = 'special:' + rule
    config = HERE.parents[1] / 'dotfiles/hyprland/.config/hypr/hyprland.lua'
    wrapper = args.output / 'hyprland.lua'
    wrapper.write_text('local on=hl.on\nhl.on=function(e,cb) if e~="hyprland.start" then return on(e,cb) end end\n'
                       + 'dofile(' + json.dumps(str(config)) + ')\nhl.on=on\n'
                       + 'hl.config({misc={disable_splash_rendering=true,disable_watchdog_warning=true,disable_hyprland_guiutils_check=true}})\n'
                       + f'hl.monitor({{output="WAYLAND-1",mode="1290x720@120",scale={args.scale}}})\n')
    (args.output / 'canvas-state.lua').write_bytes(config.with_name('canvas-state.lua').read_bytes())
    qml = args.output / 'text.qml'
    qml.write_text('''import QtQuick
import QtQuick.Window
import Quickshell
ShellRoot {
PanelWindow {
    anchors { top: true; left: true; right: true }
    implicitHeight: 52
    exclusiveZone: 52
    color: "#171717"
}
FloatingWindow {
    id: window
    visible: true
    title: "Canvas text sampling fixture"
    color: "#171717"
    implicitWidth: 600
    implicitHeight: 400
    Rectangle { x: 16; y: 16; width: 4; height: 4; color: "#00ffff" }
    Text {
        x: 32; y: 16
        text: "CLOSED, not merged.\\nwork Cockpit rail text\\nUpdating publication progress"
        color: "#eeeeee"
        font.family: "BerkeleyMono Nerd Font"
        font.pixelSize: 14
        property real dpr: window.devicePixelRatio
        onDprChanged: console.log("TEXT_DPR", dpr)
        Component.onCompleted: console.log("TEXT_DPR", dpr)
    }
}
}
''')
    env = os.environ.copy()
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NOTIFY_SOCKET', 'SWAYSOCK', 'NIRI_SOCKET'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(args.output / 'config'),
               XDG_STATE_HOME=str(args.output / 'state'), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation')
    processes, logs, samples = [], [], []
    listener, rule_added = None, False
    result = {'binary_sha256': helpers.sha(args.binary), 'runner_sha256': helpers.sha(__file__),
              'config_sha256': helpers.sha(config), 'qml_sha256': helpers.sha(qml),
              'parent_binary_sha256': helpers.sha(f'/proc/{parent_pid}/exe'),
              'scale': args.scale, 'samples': samples, 'passed': False}

    def launch(command, environment, name, **kwargs):
        log = (args.output / name).open('w')
        logs.append(log)
        proc = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        processes.append(proc)
        return proc

    try:
        assert parent('eval ' + rule + '=hl.window_rule({name=' + json.dumps(rule)
                      + ',match={class="^aquamarine$"},workspace=' + json.dumps(workspace + ' silent')
                      + ',float=true,size="1290 720",no_initial_focus=true,no_focus=true,render_unfocused=true})').strip() == 'ok'
        rule_added = True
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / 'text-test'))
        listener.listen(16)
        childenv = dict(env, WAYLAND_DISPLAY=str(args.parent_instance.parent.parent / parent_display),
                        AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none')
        child = launch([str(args.binary), '--socket', 'text-test', '--wayland-fd', str(listener.fileno()),
                        '--config', str(wrapper)], childenv, 'compositor.log', pass_fds=(listener.fileno(),))
        instance = helpers.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None), [child])
        ctl = lambda command: helpers.ipc(instance, command)
        outer = helpers.wait(lambda: next((w for w in json.loads(parent('j/clients')) if w['pid'] == child.pid), None), [child])
        assert outer['floating'] and outer['workspace']['address'] == workspace
        assert json.loads(parent('j/activewindow')).get('pid') != child.pid
        assert not ctl('configerrors').strip()
        appenv = dict(env, WAYLAND_DISPLAY='text-test', QT_QPA_PLATFORM='wayland')
        app = launch(['quickshell', '-p', str(qml)], dict(appenv, WAYLAND_DEBUG='client'), 'text.log')
        clients = helpers.wait(lambda: json.loads(ctl('j/clients')), [child, app])
        assert len(clients) == 1 and not clients[0]['floating'], 'fixture must use the tiled Canvas path'
        time.sleep(3)
        assert json.loads(ctl('j/monitors'))[0]['reserved'] == [0, 52, 0, 0]
        dprs = re.findall(r'TEXT_DPR ([\d.]+)', (args.output / 'text.log').read_text())
        assert any(abs(float(dpr) - args.scale) < .0001 for dpr in dprs), 'fixture did not reach the requested DPR'
        references = {}

        def dispatch(action):
            assert ctl('dispatch hl.dsp.layout(' + json.dumps(action) + ')').strip() == 'ok'

        def capture(name, reference=False):
            clients = json.loads(ctl('j/clients'))
            size = tuple(clients[0]['size'])
            ppm = subprocess.check_output(['grim', '-o', 'WAYLAND-1', '-t', 'ppm', '-'], env=appenv, timeout=8)
            _, dimensions, _, pixels = ppm.split(b'\n', 3)
            width, height = map(int, dimensions.split())
            assert (width, height) == (1290, 720)
            (args.output / (name + '.ppm')).write_bytes(ppm)
            marker = [i // 3 for i in range(0, len(pixels), 3) if pixels[i:i+3] == b'\x00\xff\xff']
            assert marker, 'cyan anchor missing'
            x, y = min(i % width for i in marker) + 15, min(i // width for i in marker) - 3
            assert 0 <= x and x + 450 < width and 0 <= y and y + 90 < height
            def crop(dx, dy):
                return b''.join(pixels[((y+dy+j)*width+x+dx)*3:((y+dy+j)*width+x+dx+450)*3] for j in range(90))
            image = crop(0, 0)
            if reference:
                assert clients[0]['floating']
                references[size] = image
            expected = references[size]
            aligned = min((crop(dx, dy) for dy in (-1, 0, 1) for dx in (-1, 0, 1)),
                          key=lambda candidate: sum(abs(a - b) for a, b in zip(expected, candidate)))
            difference = sum(a != b for a, b in zip(expected, aligned))
            maximum_delta = max(abs(a - b) for a, b in zip(expected, aligned))
            (args.output / (name + '-text.ppm')).write_bytes(b'P6\n450 90\n255\n' + image)
            row = {'name': name, 'changed_channels_after_integer_alignment': difference, 'maximum_channel_delta': maximum_delta,
                   'text_sha256': hashlib.sha256(image).hexdigest(), 'clients': clients}
            samples.append(row)
            print(json.dumps({k: row[k] for k in ('name', 'changed_channels_after_integer_alignment', 'maximum_channel_delta')}), flush=True)

        sizes = [json.loads(ctl('j/clients'))[0]['size']]
        dispatch('resize l')
        time.sleep(2)
        sizes.append(json.loads(ctl('j/clients'))[0]['size'])
        dispatch('resize h')
        time.sleep(2)
        assert ctl('dispatch hl.dsp.window.float()').strip() == 'ok'
        assert ctl('dispatch hl.dsp.window.move({x=60,y=60})').strip() == 'ok'
        for n, (width, height) in enumerate(sizes):
            assert ctl(f'dispatch hl.dsp.window.resize({{x={width},y={height}}})').strip() == 'ok'
            time.sleep(2)
            assert json.loads(ctl('j/clients'))[0]['size'] == [width, height]
            capture(f'floating-reference-{n}', reference=True)
        assert ctl('dispatch hl.dsp.window.float()').strip() == 'ok'
        time.sleep(2)
        assert not json.loads(ctl('j/clients'))[0]['floating']
        capture('centered')
        dispatch('pan-begin')
        for n in range(1, 5):
            dispatch('pan 0.2 0')
            time.sleep(1.5)
            capture(f'fractional-pan-{n}')
        dispatch('pan-end')
        time.sleep(2)
        capture('committed')
        for n, direction in enumerate(('l', 'h', 'l', 'h')):
            dispatch('resize ' + direction)
            time.sleep(2)
            capture(f'resize-{n}')
        assert not ctl('configerrors').strip()
        assert result['config_sha256'] == helpers.sha(config)
        result['text_stable'] = all(row['maximum_channel_delta'] <= 1 for row in samples)
        if args.expect_stable:
            assert result['text_stable'], 'unchanged text changed its sampling after camera/resize settlement'
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
        result['parent_binary_unchanged'] = helpers.sha(f'/proc/{parent_pid}/exe') == result['parent_binary_sha256']
        assert result['parent_binary_unchanged']
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    main()
