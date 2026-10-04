import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent / 'tuning'


def run_palette(args, directory, child, ctl, env, dispatch, capture, keycheck, r):
    def command(*argv):
        return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=10, check=True).stdout
    def state():
        return json.loads(command('python3', str(ROOT / 'tune.py'), 'state'))
    def keys(*names):
        command(str(args.key_sender), '--keys', *names)
    def layers():
        return [layer for monitor in json.loads(ctl('j/layers')).values() for group in monitor['levels'].values() for layer in group if layer['namespace'] == 'canvas-tuning']
    def keylog():
        return {p.name: (p / 'keys').read_text() if (p / 'keys').exists() else '' for p in directory.glob('app[0-9]')}
    def value(key):
        return next(row for row in state()['rows'] if row['key'] == key)
    def select(text):
        command('wtype', '-M', 'ctrl', 'a', '-m', 'ctrl', text)
        time.sleep(.2)
    def wait_open():
        r.wait(lambda: layers(), [child])
        time.sleep(.3)
    def close():
        keys('esc')
        r.wait(lambda: not layers(), [child])
        time.sleep(.3)
    def counters(pid):
        try:
            return r.counters(pid)
        except AssertionError:
            fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            return dict(time=time.monotonic(), gfx_ns=None, cpu_ticks=int(fields[11]) + int(fields[12]))
    def idle(label):
        time.sleep(1)
        before = [counters(pid) for pid in (child.pid, shell['pid'])]
        time.sleep(2)
        after = [counters(pid) for pid in (child.pid, shell['pid'])]
        return dict(label=label, processes=[dict(pid=pid, seconds=b['time']-a['time'], gpu_ms=(b['gfx_ns']-a['gfx_ns'])/1e6 if a['gfx_ns'] is not None and b['gfx_ns'] is not None else None, cpu_ticks=b['cpu_ticks']-a['cpu_ticks']) for pid,a,b in zip((child.pid,shell['pid']),before,after)])

    r.wait(lambda: 'canvas-tuning' in command('qs', 'ipc', '-p', str(ROOT), 'show'), [child])
    shell = next(q for q in json.loads(command('qs', 'list', '-p', str(ROOT), '-j')) if q['config_path'] == str(ROOT / 'shell.qml'))
    evidence = dict(initial=state(), checks=[], idle=[])
    assert len(evidence['initial']['rows']) == 8
    assert not layers()
    evidence['idle'].append(idle('closed-before'))
    keys('ctrl+comma')
    wait_open()
    previous = keylog()
    command('wtype', 'zzzz-no-match')
    capture('no-matches')
    assert keylog() == previous
    select('focus duration')
    keys('right')
    assert value('focus_duration')['display'] == '850 MS', state()
    keys('shift+left')
    assert value('focus_duration')['display'] == '840 MS'
    keys('home')
    assert value('focus_duration')['display'] == '800 MS'
    close()
    keycheck('normal-after-close')
    dispatch('overview')
    time.sleep(1.2)
    keys('ctrl+comma')
    wait_open()
    capture('palette-overview')
    previous = keylog()
    changes = [('grid opacity','grid_opacity','24 %'), ('grid spacing','grid_spacing','104 PX'),
               ('backdrop dim','backdrop_dim','40 %'), ('accent','focus_color','#74B9FF'),
               ('selection gap','selection_gap','5 PX'), ('minimap size','minimap_size','256 PX'),
               ('panel opacity','panel_opacity','95 %')]
    for query, key, expected in changes:
        select(query)
        keys('right')
        assert value(key)['display'] == expected, (key, state())
        evidence['checks'].append(dict(key=key, accepted=value(key)))
    select('grid opacity')
    keys(*(['left'] * 30))
    assert value('grid_opacity')['display'] == '0 %'
    keys(*(['right'] * 30))
    assert value('grid_opacity')['display'] == '50 %'
    keys('home', 'right')
    saved = Path(env['XDG_CONFIG_HOME']) / 'hypr/canvas-tuning.lua'
    backup = saved.with_suffix('.backup')
    saved.rename(backup)
    saved.mkdir()
    try:
        keys('right')
        assert value('grid_opacity')['display'] == '26 %'
        capture('save-failure')
        failed = json.loads(command('python3', str(ROOT / 'tune.py'), 'step', 'grid_opacity', '1'))
        assert failed['message'].startswith('APPLIED, NOT SAVED:'), failed
        evidence['save_failure'] = failed
    finally:
        saved.rmdir()
        backup.rename(saved)
    keys('home', 'right')
    assert value('grid_opacity')['display'] == '24 %'
    assert keylog() == previous, 'palette text/arrows leaked into app'
    select('')
    keys('down', 'down')
    capture('palette-adjusted')
    evidence['idle'].append(idle('open-settled'))
    close()
    capture('world-adjusted')
    keycheck('overview-after-close')
    evidence['idle'].append(idle('closed-after'))
    for _ in range(3):
        keys('ctrl+comma')
        wait_open()
        close()
        keycheck('repeated-close')
    keys('ctrl+comma')
    wait_open()
    os.kill(shell['pid'], signal.SIGTERM)
    r.wait(lambda: not layers(), [child])
    keycheck('palette-process-exit')
    evidence['saved'] = state()
    evidence['fragment'] = (Path(env['XDG_CONFIG_HOME']) / 'hypr/canvas-tuning.lua').read_text()
    dispatch('overview')
    time.sleep(1.2)
    keycheck('normal-after-process-exit')
    (directory / 'palette-evidence.json').write_text(json.dumps(evidence, indent=2))
    return evidence
