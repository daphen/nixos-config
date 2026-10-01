"""Floating windows stay flat and receive unwarped client-local pointer input."""
import importlib.util
import json
from pathlib import Path
import subprocess
import time


def run_floating(args, directory, ctl, appenv, dispatch, capture):
    editor = next(w for w in json.loads(ctl('j/clients')) if w['title'].startswith('Editor'))
    selector = json.dumps('address:' + editor['address'])
    for action in (f'hl.dsp.focus({{window={selector}}})',
                   f'hl.dsp.window.float({{action="toggle",window={selector}}})',
                   f'hl.dsp.window.resize({{x=360,y=350,window={selector}}})',
                   f'hl.dsp.window.move({{x=1000,y=180,window={selector}}})'):
        reply = ctl('dispatch ' + action)
        assert reply.strip() == 'ok', (action, reply)
    time.sleep(1)
    editor = next(w for w in json.loads(ctl('j/clients')) if w['address'] == editor['address'])
    assert editor['floating'] and editor['at'] == [1000, 180] and editor['size'] == [360, 350], editor
    capture('floating-normal')
    dispatch('overview')
    time.sleep(1)
    capture('floating-overview')
    crop = 'crop=320:310:1020:200'
    pixels = [subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(directory / (name + '.png')),
                                      '-vf', crop, '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], timeout=10)
              for name in ('floating-normal', 'floating-overview')]
    changed = sum(a != b for a, b in zip(*pixels))
    result = {'window': editor, 'changed_color_channels': changed, 'crop': crop}
    (directory / 'floating.json').write_text(json.dumps(result, indent=2) + '\n')
    assert changed == 0, ('floating window changed under world lens', changed)
    spec = importlib.util.spec_from_file_location('pointer_fixture', Path(__file__).with_name('test-canvas-x11-input.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pointer = module.Pointer(Path(appenv['XDG_RUNTIME_DIR']) / appenv['WAYLAND_DISPLAY'])
    try:
        pointer.move(round(1060 / 1440 * 1280), round(290 / 900 * 720))
        pointer.click()
        time.sleep(.3)
        actual = json.loads((directory / 'app0/clicks').read_text().splitlines()[-1])
        assert abs(actual[0] - 60) < 2 and abs(actual[1] - 110) < 2, actual
        assert json.loads(ctl('j/activewindow'))['address'] == editor['address']
        result['client_local_click'] = actual
    finally:
        pointer.sock.close()
    (directory / 'floating.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
