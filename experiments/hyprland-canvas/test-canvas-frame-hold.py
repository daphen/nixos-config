#!/usr/bin/env python3
"""Nested check: background windows get no frame callbacks while the camera animates, and resume once it settles."""
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

spec = importlib.util.spec_from_file_location('rendering', Path(__file__).resolve().parent / 'test-canvas-rendering.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
runtime = Path(tempfile.mkdtemp(prefix='c', dir=os.environ['XDG_RUNTIME_DIR']))
runtime.chmod(0o700)
env = {k: v for k, v in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NOTIFY_SOCKET')}
env.update(XDG_RUNTIME_DIR=str(runtime), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none',
           XDG_STATE_HOME=str(args.output / 'state'), XDG_CONFIG_HOME=str(args.output / 'config'))
processes = []
# WAYLAND_DEBUG stamps are wall-clock microseconds modulo 2**32.
stamp = lambda: (int(time.time() * 1e6) % 2**32) / 1e6


def launch(command, environment, log, **kwargs):
    process = subprocess.Popen(command, env=environment, stdout=log.open('w'), stderr=subprocess.STDOUT, **kwargs)
    processes.append(process)
    return process


def callbacks(log):
    times = []
    for line in log.read_text(errors='replace').splitlines():
        match = re.match(r'\[\s*(\d+)\.(\d+)\]\s.*wl_callback#\d+\.done', line)
        if match:
            times.append((int(match[1]) * 1000 + int(match[2])) / 1e6)
    return times


try:
    config = args.output / 'hyprland.lua'
    config.write_text('package.path=' + json.dumps(str(r.CONFIG.resolve().parent) + '/?.lua;') + '..package.path\nlocal on=hl.on\n'
                      'hl.on=function(event,cb) if event~="hyprland.start" then return on(event,cb) end end\n'
                      'dofile(' + json.dumps(str(r.CONFIG.resolve())) + ')\nhl.on=on\nhl.config({misc={disable_splash_rendering=true}})\n')
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(runtime / 'nested'))
    listener.listen(16)
    compositor = launch([str(args.binary), '--socket', 'nested', '--wayland-fd', str(listener.fileno()), '--config', str(config)],
                        dict(env, WAYLAND_DISPLAY=str(Path(os.environ['XDG_RUNTIME_DIR']) / os.environ['WAYLAND_DISPLAY'])),
                        args.output / 'compositor.log', pass_fds=(listener.fileno(),))
    instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None)
                      if (runtime / 'hypr').exists() else None, [compositor])
    ctl = lambda command: r.ipc(instance, command)
    assert not ctl('configerrors').strip(), ctl('configerrors')
    assert ctl('eval hl.monitor({output="HEADLESS-1",mode="1920x1080@60",position="0x0",scale=1})').strip() == 'ok'
    assert ctl('output create headless HEADLESS-1').strip() == 'ok'
    r.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [compositor])
    assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
    appenv = dict(env, WAYLAND_DISPLAY='nested', HYPRLAND_INSTANCE_SIGNATURE=instance.name, WAYLAND_DEBUG='client')
    for title in ('A', 'B', 'C'):
        launch(['kitty', '--title', title, '-o', 'repaint_delay=0', '-o', 'sync_to_monitor=yes', 'sh', '-c', 'while :; do date +%N; sleep 0.004; done'],
               appenv, args.output / (title + '.log'))
        r.wait(lambda: title in [c['title'] for c in json.loads(ctl('j/clients'))], [compositor])
        time.sleep(1)
    clients = {c['title']: c for c in json.loads(ctl('j/clients'))}
    assert ctl('dispatch hl.dsp.focus({window="address:' + clients['A']['address'] + '"})').strip() == 'ok'
    time.sleep(2)
    marks = {}
    for phase in ('out', 'in'):
        marks[phase] = stamp()
        assert ctl('dispatch hl.dsp.layout("overview")').strip() == 'ok'
        time.sleep(2.5)
finally:
    for process in reversed(processes):
        process.terminate()
    for process in processes:
        try:
            process.wait(5)
        except subprocess.TimeoutExpired:
            process.kill()

result = {}
for title in ('A', 'B', 'C'):
    stamps = callbacks(args.output / (title + '.log'))
    count = lambda start, stop: sum(start <= t < stop for t in stamps)
    result[title] = {'zoom_out_first_150ms': count(marks['out'], marks['out'] + .15),
                     'settled_overview_last_1s': count(marks['in'] - 1, marks['in']),
                     'zoom_in_first_150ms': count(marks['in'], marks['in'] + .15)}
print(json.dumps(result, indent=1))
(args.output / 'result.json').write_text(json.dumps(result, indent=1))
