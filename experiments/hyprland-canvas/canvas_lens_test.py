"""Public-key tiling preservation for the world projection candidate."""
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import time


def run_lens(args, directory, ctl, appenv, capture, keycheck, lens, fit_overview=False):
    def windows():
        return json.loads(ctl('j/clients'))

    def geometry():
        return sorted((w['title'], w['at'], w['size'], w['floating']) for w in windows())

    def rows():
        groups = {}
        for w in windows():
            groups.setdefault(w['at'][1], []).append(w)
        return [[w['title'] for w in sorted(group, key=lambda w: w['at'][0])] for y, group in sorted(groups.items())]

    def held(chord):
        return subprocess.Popen([str(args.key_sender), '--hold', '3000', chord], env=appenv, stdout=subprocess.DEVNULL)

    def mode_pixel(label):
        capture(label)
        return subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / (label + '.png')),
                                       '-vf', f'crop=2:2:{round(40 * args.scale)}:{round(40 * args.scale)}', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=5)[:3]

    normal_pixel = mode_pixel('input-normal-reference')
    initial = geometry()
    selected = json.loads(ctl('j/activewindow'))['address']
    original_rows = rows()
    assert [len(row) for row in original_rows] == [2, 2], original_rows
    results = []
    framing = []
    if fit_overview:
        for target in windows():
            ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + target['address']) + '})')
            ctl('dispatch hl.dsp.layout("camera-center")')
            time.sleep(1)
            before = geometry()
            with held('super+tab') as sender:
                time.sleep(1)
                assert json.loads(ctl('j/activewindow'))['address'] == target['address']
                assert mode_pixel('fit-from-' + target['title'].split(' / ')[0]) != normal_pixel
                sender.wait(timeout=5)
            time.sleep(1)
            assert json.loads(ctl('j/activewindow'))['address'] == target['address'], 'overview return changed selection'
            assert geometry() == before, 'overview changed tiled geometry'
            framing.append(target['title'])
        ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + selected) + '})')
        ctl('dispatch hl.dsp.layout("camera-center")')
        time.sleep(1)
        assert geometry() == initial
    for mode in ('normal', 'overview'):
        for chord in ('super+shift+j', 'super+shift+k', 'alt+shift+j', 'alt+shift+k'):
            if mode == 'overview':
                ctl('dispatch hl.dsp.layout("overview")')
                time.sleep(1)
            before = rows()
            with held(chord) as sender:
                time.sleep(1)
                after = rows()
                assert after != before, (mode, chord, before, after)
                assert json.loads(ctl('j/activewindow'))['address'] == selected, (mode, chord, 'lost keyboard focus')
                assert all(not w['floating'] for w in windows())
                if chord.startswith('super'):
                    expected_lengths = [1, 3] if chord.endswith('j') else [2, 2]
                    assert [len(row) for row in after] == expected_lengths, (chord, after)
                else:
                    assert after == before[::-1], (chord, before, after)
                pixel = mode_pixel('tiling-' + mode + '-' + chord.replace('+', '-'))
                assert (pixel != normal_pixel) == (mode == 'overview'), (mode, chord, 'rendered mode mismatch', pixel.hex())
                results.append({'mode': mode, 'key': chord, 'before': before, 'after': after, 'focus': selected, 'mode_pixel': pixel.hex()})
                sender.wait(timeout=5)
            assert sender.returncode == 0, sender.returncode
            ctl('dispatch hl.dsp.layout("pan-end")')
            time.sleep(1)
            if mode == 'overview':
                ctl('dispatch hl.dsp.layout("overview")')
                time.sleep(1)
                assert mode_pixel('delivery-' + chord.replace('+', '-')) != normal_pixel
            keycheck(mode + '-' + chord)
            ctl('dispatch hl.dsp.layout("pan-end")')
            time.sleep(1)
        assert rows() == original_rows
        assert geometry() == initial, (mode, initial, geometry())
    spec = importlib.util.spec_from_file_location('pointer_fixture', Path(__file__).with_name('test-canvas-x11-input.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pointer = module.Pointer(Path(appenv['XDG_RUNTIME_DIR']) / appenv['WAYLAND_DISPLAY'])
    monitor = json.loads(ctl('j/monitors'))[0]
    width, height = monitor['width'] / monitor['scale'], monitor['height'] / monitor['scale']
    reserved = monitor['reserved']
    area = [reserved[0], reserved[1], width - reserved[0] - reserved[2], height - reserved[1] - reserved[3]]
    pointer_results = []
    try:
        for target in sorted(windows(), key=lambda w: w['title']):
            ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + selected) + '})')
            ctl('dispatch hl.dsp.layout("camera-center")')
            time.sleep(1)
            current = windows()
            anchor = next(w for w in current if w['address'] == selected)
            bounds = [min(w['at'][axis] for w in current) for axis in (0, 1)]
            extent = [max(w['at'][axis] + w['size'][axis] for w in current) - bounds[axis] for axis in (0, 1)]
            zoom = max(.25, min(1, area[2] / (extent[0] + 96), area[3] / (extent[1] + 96)))
            center = [bounds[axis] + extent[axis] / 2 if fit_overview else anchor['at'][axis] + anchor['size'][axis] / 2 for axis in (0, 1)]
            offset = [area[axis] + area[axis + 2] / 2 - center[axis] * zoom for axis in (0, 1)]
            fraction = [.88 if target['title'].startswith('Notes') else .4, .15]
            source = [(target['at'][axis] + target['size'][axis] * fraction[axis]) * zoom + offset[axis] for axis in (0, 1)]
            centered = [source[0] / width * 2 - 1, source[1] / height * 2 - 1]
            radius = math.hypot(*centered)
            warped_radius = radius
            if lens:
                for _ in range(10):
                    warped_radius -= (warped_radius * (1 + .14 * warped_radius ** 2) / 1.08 - radius) / ((1 + .42 * warped_radius ** 2) / 1.08)
            point = [(centered[axis] * (warped_radius / radius if radius else 1) + 1) / 2 * (width, height)[axis] for axis in (0, 1)]
            assert 0 < point[0] < width and 0 < point[1] < height, point
            assert not (point[0] > width - 270 and point[1] > height - 200), 'target intersects minimap'
            with held('super+tab') as sender:
                time.sleep(1)
                pixel = mode_pixel('pointer-' + str(len(pointer_results)))
                assert pixel != normal_pixel, 'pointer test is not in overview'
                pointer.move(round(point[0] / width * 1280), round(point[1] / height * 720))
                actual_pointer = json.loads(ctl('j/cursorpos'))
                pointer.click()
                time.sleep(1)
                focused = json.loads(ctl('j/activewindow'))
                assert focused['address'] == target['address'], (target['title'], point, actual_pointer, focused['title'])
                pointer_results.append({'target': target['title'], 'point': point, 'actual_pointer': actual_pointer, 'source': source, 'zoom': zoom})
                sender.wait(timeout=5)
            assert sender.returncode == 0, sender.returncode
            keycheck('pointer-' + target['title'])
        ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + selected) + '})')
        ctl('dispatch hl.dsp.layout("camera-center")')
        time.sleep(1)
        assert geometry() == initial
    finally:
        pointer.sock.close()
    oversized = None
    if fit_overview:
        subprocess.run([str(args.key_sender), '--keys', *(['super+ctrl+l'] * 13), *(['super+ctrl+k'] * 4)], env=appenv, check=True, stdout=subprocess.DEVNULL)
        time.sleep(1)
        focused = json.loads(ctl('j/activewindow'))
        assert focused['address'] == selected and focused['size'][0] > area[2] and focused['size'][1] > area[3]
        capture('oversized-title-visible')
        pixel = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / 'oversized-title-visible.png'),
                                         '-vf', f'crop=2:2:{round(80 * args.scale)}:{round(10 * args.scale)}', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=5)[:3]
        assert pixel == bytes((28, 32, 40)), ('oversized header not visible', pixel.hex())
        keycheck('oversized-title')
        oversized = {'size': focused['size'], 'header_pixel': pixel.hex()}
        subprocess.run([str(args.key_sender), '--keys', *(['super+ctrl+h'] * 13), *(['super+ctrl+j'] * 4)], env=appenv, check=True, stdout=subprocess.DEVNULL)
        time.sleep(1)
        assert geometry() == initial, 'resizing back changed tiled geometry'
    result = {'tiling': results, 'pointer': pointer_results, 'framing_focus_preserved': framing, 'oversized': oversized}
    (directory / 'lens-input.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
