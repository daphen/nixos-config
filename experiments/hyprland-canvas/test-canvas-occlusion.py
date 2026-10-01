#!/usr/bin/env python3
"""A/B/A rendering comparison inside a private, GPU-backed headless desktop."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile

RUNNER = Path(__file__).with_name('test-canvas-rendering.py')
spec = importlib.util.spec_from_file_location('rendering', RUNNER)
rendering = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rendering)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--wallpaper', type=Path, required=True)
    parser.add_argument('--scale', type=float, choices=(1, 1.5), default=1)
    parser.add_argument('--size', type=int, nargs=2, default=(1296, 720), metavar=('WIDTH', 'HEIGHT'))
    args = parser.parse_args()
    width, height = args.size
    assert width > 0 and height > 0
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    runtime = Path(tempfile.mkdtemp(prefix='cp-'))
    live = lambda cmd: rendering.ipc(args.parent_instance, cmd)
    live_pid, live_display = (args.parent_instance / 'hyprland.lock').read_text().splitlines()
    live_hash = rendering.sha(f'/proc/{live_pid}/exe')
    config = args.output / 'hyprland.lua'
    config.write_text('local on=hl.on\nhl.on=function(event,cb) if event~="hyprland.start" then return on(event,cb) end end\n'
                      + 'dofile(' + json.dumps(str(rendering.CONFIG)) + ')\nhl.on=on\nhl.config({misc={disable_splash_rendering=true}})\n'
                      + 'hl.monitor({output="WAYLAND-1",mode="1296x720@120",scale=1})\n')
    (args.output / 'canvas-state.lua').write_bytes(rendering.CONFIG.with_name('canvas-state.lua').read_bytes())
    env = os.environ.copy()
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NIRI_SOCKET', 'SWAYSOCK', 'NOTIFY_SOCKET'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(args.output / 'state'), XDG_CONFIG_HOME=str(args.output / 'config'),
               HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation', WAYLAND_DISPLAY=str(args.parent_instance.parent.parent / live_display),
               AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none')
    rule = 'canvas_private_parent_' + str(os.getpid())
    parent = background = None
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(runtime / 'canvas-parent'))
    listener.listen(16)
    log = (args.output / 'parent.log').open('w')
    try:
        assert live('eval ' + rule + '=hl.window_rule({name="' + rule + '",match={class="^aquamarine$"},workspace="special:'
                    + rule + ' silent",float=true,no_initial_focus=true,no_focus=true})').strip() == 'ok'
        parent = subprocess.Popen([str(args.baseline), '--socket', 'canvas-parent', '--wayland-fd', str(listener.fileno()), '--config', str(config)],
                                  env=env, stdout=log, stderr=subprocess.STDOUT, pass_fds=(listener.fileno(),))
        instance = rendering.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None), [parent])
        ctl = lambda cmd: rendering.ipc(instance, cmd)
        assert ctl(f'eval hl.monitor({{output="HEADLESS-1",mode="{width}x{height}@120",position="0x0",scale=1}})').strip() == 'ok'
        assert ctl('output create headless HEADLESS-1').strip() == 'ok'
        rendering.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [parent])
        assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
        rendering.wait(lambda: all(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [parent])
        background = subprocess.Popen(['swaybg', '-o', 'HEADLESS-1', '-c', '#000000'], env=dict(env, WAYLAND_DISPLAY='canvas-parent'),
                                      stdout=log, stderr=subprocess.STDOUT)
        rendering.wait(lambda: 'wallpaper' in ctl('j/layers'), [parent, background])
        for name, binary in (('control', args.baseline), ('candidate', args.candidate), ('control-repeat', args.baseline)):
            monitors = json.loads(ctl('j/monitors'))
            assert len(monitors) == 1 and monitors[0]['hardwareDetails']['backend'] == 'headless'
            command = ['python3', str(RUNNER), '--binary', str(binary), '--parent-instance', str(instance), '--output', str(args.output / name),
                       '--ffmpeg', args.ffmpeg, '--visible', '--pan-only', '--wallpaper', str(args.wallpaper), '--repeats', '3', '--scale', str(args.scale),
                       '--size', str(width), str(height)]
            if name != 'control':
                command += ['--reference', str(args.output / 'control')]
            with (args.output / (name + '.log')).open('w') as runlog:
                subprocess.run(command, check=True, stdout=runlog, stderr=subprocess.STDOUT)
            print(name + ' complete', flush=True)
    finally:
        for proc in (background, parent):
            if proc and proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                proc.wait(timeout=15)
        listener.close()
        log.close()
        assert live('eval ' + rule + ':set_enabled(false);' + rule + '=nil').strip() == 'ok'
        assert rendering.sha(f'/proc/{live_pid}/exe') == live_hash


if __name__ == '__main__':
    main()
