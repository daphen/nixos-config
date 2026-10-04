#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import socket
import sys
import tempfile

PRESETS = [0xffff6b1a, 0xff74b9ff, 0xffa3be8c, 0xffb48ead, 0xffebcba2]
ROWS = [
    ('focus_duration', 'MOTION', 'FOCUS DURATION', 800, 300, 1000, 50, 10, 'MS', 1),
    ('grid_opacity', 'WORLD', 'GRID OPACITY', .22, 0, .5, .02, .01, '%', 100),
    ('grid_spacing', 'WORLD', 'GRID SPACING', 96, 48, 144, 8, 1, 'PX', 1),
    ('backdrop_dim', 'WORLD', 'BACKDROP DIM', .35, 0, .65, .05, .01, '%', 100),
    ('focus_color', 'CHROME', 'ACCENT', PRESETS[0], 0, 4, 1, 1, '', 1),
    ('selection_gap', 'CHROME', 'SELECTION GAP', 4, 0, 12, 1, .25, 'PX', 1),
    ('minimap_size', 'CHROME', 'MINIMAP SIZE', 240, 160, 320, 16, 4, 'PX', 1),
    ('panel_opacity', 'CHROME', 'PANEL OPACITY', .9, .3, 1, .05, .01, '%', 100),
]
CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'hypr/canvas-tuning.lua'


def ipc(command):
    path = Path(os.environ['XDG_RUNTIME_DIR']) / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        connection.sendall(command.encode())
        chunks = []
        while chunk := connection.recv(65536):
            chunks.append(chunk)
    return b''.join(chunks).decode()


def read_values():
    animation = next(a for a in json.loads(ipc('j/animations'))[0] if a['name'] == 'canvasFocus')
    values = {'focus_duration': animation['speed'] * 100}
    for key, *_ in ROWS[1:]:
        option = json.loads(ipc('j/getoption experimental:canvas_' + key))
        values[key] = option['int'] if key == 'focus_color' else option['float']
    return values


def lua(key, value):
    if key == 'focus_duration':
        return 'hl.animation({leaf="canvasFocus",enabled=true,speed=%.2f,bezier="canvasCameraEase"})' % (value / 100)
    literal = '"rgb(%06x)"' % (int(value) & 0xffffff) if key == 'focus_color' else str(value)
    return 'hl.config({experimental={canvas_%s=%s}})' % (key, literal)


def adjust(action, key, direction=0, fine=False):
    spec = next(row for row in ROWS if row[0] == key)
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    with CONFIG.with_suffix('.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = read_values()[key]
        if action == 'reset':
            value = spec[3]
        elif key == 'focus_color':
            index = PRESETS.index(int(current)) if int(current) in PRESETS else 0
            value = PRESETS[(index + direction) % len(PRESETS)]
        else:
            value = round(min(spec[5], max(spec[4], current + direction * spec[7 if fine else 6])), 4)
        response = ipc('eval ' + lua(key, value))
        if response.strip() != 'ok':
            raise RuntimeError(response)
        accepted = read_values()
        if abs(accepted[key] - value) > .001:
            raise RuntimeError('Compositor did not accept the requested value')
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=CONFIG.parent, prefix='.canvas-tuning-', delete=False) as out:
                out.write('\n'.join(lua(row[0], accepted[row[0]]) for row in ROWS) + '\n')
                temporary = Path(out.name)
            try:
                os.replace(temporary, CONFIG)
            finally:
                temporary.unlink(missing_ok=True)
        except OSError as error:
            return 'APPLIED, NOT SAVED: ' + str(error)
    return 'SAVED • LIVE PREVIEW'


message = 'LIVE VALUES • CHANGES SAVE AUTOMATICALLY'
try:
    action = sys.argv[1]
    if action != 'state':
        assert action in ('step', 'reset')
        message = adjust(action, sys.argv[2], int(sys.argv[3]) if action == 'step' else 0, len(sys.argv) > 4 and sys.argv[4] == 'fine')
    values = read_values()
    rows = []
    for key, category, label, default, low, high, step, fine, unit, factor in ROWS:
        value = values[key]
        color = key == 'focus_color'
        display = '#%06X' % (int(value) & 0xffffff) if color else '%g %s' % (round(value * factor, 2), unit)
        fraction = (PRESETS.index(int(value)) / 4 if int(value) in PRESETS else 0) if color else (value - low) / (high - low)
        rows.append(dict(key=key, category=category, label=label, display=display, fraction=fraction))
    monitor = next(m for m in json.loads(ipc('j/monitors')) if m['focused'])
    print(json.dumps(dict(rows=rows, accent='#%06x' % (int(values['focus_color']) & 0xffffff), output=monitor['name'], message=message)))
except Exception as error:
    print(json.dumps(dict(error=str(error))))
    sys.exit(1)
