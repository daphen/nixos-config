"""Normal-size pan through registered Lua callbacks and the native input receiver."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import time


def run_interaction(args, directory, ctl, appenv, capture, keycheck):
    def command(value):
        reply = ctl(value).strip()
        assert reply == 'ok', (value, reply)

    def layout(value):
        command('dispatch hl.dsp.layout(' + json.dumps(value) + ')')

    def windows():
        return json.loads(ctl('j/clients'))

    def geometry():
        current = sorted(windows(), key=lambda w: w['title'])
        anchor = current[0]['at']
        return [(w['title'], [w['at'][i] - anchor[i] for i in (0, 1)], w['size'], w['floating']) for w in current]

    selected = next(w for w in windows() if w['title'].startswith('Editor'))
    initial = geometry()
    monitor = json.loads(ctl('j/monitors'))[0]
    width, height = monitor['width'], monitor['height']
    assert args.scale == 1, 'interaction pixel measurements require the requested 1x run'
    rows = []

    def reset():
        layout('pan-end')
        time.sleep(.8)
        command('dispatch hl.dsp.focus({window=' + json.dumps('address:' + selected['address']) + '})')
        layout('camera-center')
        time.sleep(.8)

    def measure(label, editor_visible=True):
        capture(label)
        raw = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / (label + '.png')),
                                       '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=10)
        stripes, edge = [], None
        for y in range(height):
            line = raw[y * width * 3:(y + 1) * width * 3]
            if line.count(bytes((40, 46, 58))) > 100:
                stripes.append(y)
            accent = bytes((102, 204, 230))
            if line.count(accent) > 120:
                edge = (line.rfind(accent) // 3, y)
        groups = []
        for y in stripes:
            if not groups or y != groups[-1][-1] + 1:
                groups.append([])
            groups[-1].append(y)
        lengths = [len(group) for group in groups]
        assert lengths.count(10) >= 3, (label, 'normal-size 10px fixture bars changed size', lengths)
        if editor_visible:
            assert edge is not None, (label, 'Editor accent not visible')
        row = {'label': label, 'time': time.monotonic(), 'bar_heights': lengths, 'editor_right_edge': edge[0] if edge else None}
        rows.append(row)
        return row['editor_right_edge']

    reset()
    for label in ('desktop-callback', 'deck-receiver'):
        reset()
        before = measure(label + '-before')
        start = time.monotonic()
        if label == 'desktop-callback':
            command('eval test_swipe.start()')
        for n in range(8):
            if label == 'desktop-callback':
                command('eval test_swipe.update({delta={x=11,y=0}})')
            else:
                layout('pan 88 0')
            time.sleep(.08)
            current = measure(label + '-' + str(n))
            assert -3 <= before - current <= (n + 1) * 88 + 4, (label, n, 'camera exceeded cumulative requested travel', before, current)
        assert time.monotonic() - start > .35
        time.sleep(.5)
        end = measure(label + '-held')
        assert 690 <= before - end <= 710, (label, 'wrong gain or spring overshoot', before - end)
        if label == 'desktop-callback':
            command('eval test_swipe.finish()')
        else:
            layout('pan-end')
        time.sleep(1)
        capture(label + '-settled')
        assert json.loads(ctl('j/activewindow'))['title'].startswith('Notes'), 'release failed to select the adjacent tile'
        assert geometry() == initial, 'pan changed tile sizes, spacing or ordering'
        keycheck(label + '-settled')
    reset()
    spec = importlib.util.spec_from_file_location('pointer_fixture', Path(__file__).with_name('test-canvas-x11-input.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pointer = module.Pointer(Path(appenv['XDG_RUNTIME_DIR']) / appenv['WAYLAND_DISPLAY'])
    try:
        with subprocess.Popen([str(args.key_sender), '--hold', '4500', 'super+ctrl+alt+x'], env=appenv, stdout=subprocess.DEVNULL) as sender:
            time.sleep(.3)
            before = measure('meta-axis-before')
            pointer.move(640, 360)
            inverted = json.loads(ctl('j/getoption input:invert_horizontal_scroll'))['bool']
            factor = json.loads(ctl('j/getoption input:touchpad:scroll_factor'))['float']
            delta = 88 / (2.5 * factor) * (-1 if inverted else 1)
            for n in range(8):
                pointer.send(5, 3, struct.pack('IIi', pointer.now(), 1, round(delta * 256)))
                pointer.send(5, 5, struct.pack('I', 1))
                pointer.send(5, 4)
                pointer.sync()
                time.sleep(.08)
                measure('meta-axis-' + str(n))
            time.sleep(.4)
            after = measure('meta-axis-held')
            assert 690 <= before - after <= 710, ('Meta+finger axis travel', before - after)
            pointer.send(5, 6, struct.pack('II', pointer.now(), 1))
            pointer.send(5, 4)
            pointer.sync()
            sender.wait(timeout=10)
            assert sender.returncode == 0
        def release_snapshot(label):
            edge = measure(label)
            editor = next(w for w in windows() if w['title'].startswith('Editor'))
            return {'focus': json.loads(ctl('j/activewindow')), 'windows': windows(), 'editor_right_edge': edge,
                    'rendered_camera_x_estimate': edge - editor['at'][0] - editor['size'][0]}
        after_keyup = release_snapshot('meta-axis-keyup')
        time.sleep(1)
        settled = json.loads(ctl('j/activewindow'))
        capture('meta-axis-released')
        if not settled['title'].startswith('Notes'):
            layout('pan-end')
            time.sleep(1)
            explicit = release_snapshot('meta-axis-explicit-end')
            diagnostic = {'after_keyup': after_keyup, 'after_wait_focus': settled, 'after_explicit_pan_end': explicit}
            (directory / 'release-diagnostic.json').write_text(json.dumps(diagnostic, indent=2) + '\n')
            raise AssertionError(('Super release failed; explicit pan-end is diagnostic only', settled['title'], explicit['focus']['title']))
        assert geometry() == initial
        keycheck('meta-axis-release')
    finally:
        pointer.sock.close()
    reset()
    with subprocess.Popen([str(args.key_sender), '--hold', '2500', 'super'], env=appenv, stdout=subprocess.DEVNULL) as sender:
        time.sleep(.2)
        for n in range(8):
            layout('pan 88 0')
            time.sleep(.06)
        time.sleep(.4)
        measure('sole-meta-held')
        sender.wait(timeout=5)
        assert sender.returncode == 0
    time.sleep(1)
    assert json.loads(ctl('j/activewindow'))['title'].startswith('Notes'), 'sole Meta release did not settle direct pan'
    assert geometry() == initial
    keycheck('sole-meta-release')
    reset()
    focus = []
    for direction, title in zip('ljhk', ('Notes', 'Browser', 'Terminal', 'Editor')):
        subprocess.run([str(args.key_sender), '--keys', 'super+' + direction], env=appenv, check=True, timeout=5)
        time.sleep(.8)
        actual = json.loads(ctl('j/activewindow'))['title']
        assert actual.startswith(title), (direction, actual, title)
        measure('normal-focus-' + direction, editor_visible=False)
        focus.append(actual)
        keycheck('normal-focus-' + direction)
    assert geometry() == initial
    result = {'passed': True, 'samples': rows, 'normal_focus': focus, 'tile_geometry_preserved': True,
              'input_coverage': 'Actual registered desktop Lua callbacks; direct layout pan receiver equivalent for Deck; real virtual-pointer finger-axis with Meta and keyboard release. No physical touchpad or Deck hardware exercised.',
              'measurement': 'Rendered 10px bars verify 1x throughout; Editor accent tracks requested 704px travel, not on-screen cadence.'}
    (directory / 'normal-pan.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
