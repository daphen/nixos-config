"""Compare production effect settings through the public canvas dispatcher."""
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def run_effects(args, directory, child, ctl, dispatch, capture, counters):
    zero = {'canvas_edge_blur': 0, 'canvas_chromatic': 0, 'canvas_vignette': 0,
            'canvas_parallax_strength': 0, 'canvas_parallax_depth': 0}
    full = dict(zero, canvas_edge_blur=.55, canvas_chromatic=.12, canvas_vignette=.65,
                canvas_parallax_strength=.06, canvas_parallax_depth=.12)
    cases = [('none', zero), ('blur', dict(zero, canvas_edge_blur=.55)),
             ('fringe', dict(zero, canvas_chromatic=.12)), ('vignette', dict(zero, canvas_vignette=.65)),
             ('parallax', dict(zero, canvas_parallax_strength=.06, canvas_parallax_depth=.12)),
             ('all-no-blur', dict(full, canvas_edge_blur=0)), ('all', full), ('none-repeat', zero)]
    windows = json.loads(ctl('j/clients'))
    editor = next(w for w in windows if w['title'].startswith('Editor'))
    path = directory / 'compositor.log'
    surface = re.search(r'get_xdg_surface\([^\n]*wl_surface[#@](\d+)\)', path.read_text())[1]
    results = []
    for name, options in cases:
        values = ','.join(f'{key}={value}' for key, value in options.items())
        assert ctl('eval hl.config({experimental={' + values + '}})').strip() == 'ok'
        for key, value in options.items():
            actual = json.loads(ctl('j/getoption experimental:' + key))
            assert abs(actual['float'] - value) < .00001, (key, value, actual)
        trials = []
        for trial in range(args.repeats):
            dispatch('pan-end')
            time.sleep(1)
            assert ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + editor['address']) + '})').strip() == 'ok'
            dispatch('camera-center')
            time.sleep(1)
            dispatch('overview')
            time.sleep(1)
            if trial == 0:
                capture('effect-' + name)
            offset = path.stat().st_size
            before = counters(child.pid)
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
            after = counters(child.pid)
            tail = path.read_bytes()[offset:].decode(errors='replace')
            stamps = re.findall(r'\[(\d+:\d+:[\d.]+)\][^\n]*-> wl_surface[#@]' + surface + r'\.commit\(', tail)
            times = [sum(float(v) * u for v, u in zip(s.split(':'), (3600000, 60000, 1000))) for s in stamps]
            gaps = [(b - a) % 86400000 for a, b in zip(times, times[1:])]
            assert len(times) > 60
            row = {'trial': trial, 'seconds': after['time'] - before['time'],
                   'gpu_ms': (after['gfx_ns'] - before['gfx_ns']) / 1e6,
                   'cpu_ms': (after['cpu_ticks'] - before['cpu_ticks']) / os.sysconf('SC_CLK_TCK') * 1000,
                   'frames': len(times), 'gap_p95_ms': sorted(gaps)[math.ceil(.95 * len(gaps)) - 1],
                   'input_max_lateness_ms': max(lateness) * 1000}
            trials.append(row)
            print('effect', name, json.dumps(row), flush=True)
        results.append({'effect': name, 'options': options, 'trials': trials})
    assert not ctl('configerrors').strip()
    (directory / 'effects.json').write_text(json.dumps(results, indent=2) + '\n')
    environment = dict(item.split('=', 1) for item in Path(f'/proc/{child.pid}/environ').read_text().split('\0') if item)
    environment['WAYLAND_DISPLAY'] = child.args[child.args.index('--socket') + 1]
    environment.pop('WAYLAND_DEBUG', None)
    instance = next(path.parent for path in (Path(environment['XDG_RUNTIME_DIR']) / 'hypr').glob('*/hyprland.lock')
                    if path.read_text().splitlines()[0] == str(child.pid))
    subprocess.run([sys.executable, str(Path(__file__).with_name('test-canvas-pan-input.py')), '--instance', str(instance),
                    '--keys', str(args.key_sender), '--directory', str(directory)], env=environment, check=True, timeout=20)
    return results
