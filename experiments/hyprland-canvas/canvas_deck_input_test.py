"""Public nested-pointer input with a test-only backend device-name fixture."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import time


def run(ctl, parent, runtime, env, keys, directory, device_name, locked=False):
    spec = importlib.util.spec_from_file_location('input_pointer', Path(__file__).with_name('test-canvas-x11-input.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pointer = module.Pointer(runtime / 'bridge')
    sender = None
    overview = lambda: bool(json.loads(ctl('j/monitors'))[0]['canvasNearest'])
    result = {'device_name': device_name, 'locked': locked, 'passed': False}
    try:
        assert parent('eval hl.config({input={emulate_discrete_scroll=0}})').strip() == 'ok'
        assert parent('eval hl.window_rule({name="input-focus",match={class="^aquamarine$"},no_focus=false})').strip() == 'ok'
        outer = next(w for w in json.loads(parent('j/clients')) if w['class'] == 'aquamarine')
        assert parent('dispatch hl.dsp.focus({window=' + json.dumps('address:' + outer['address']) + '})').strip() == 'ok'
        pointer.send(5, 1, struct.pack('IIIII', pointer.now(), 640, 400, 1280, 800))
        pointer.send(5, 4)
        pointer.sync()
        time.sleep(.3)
        mice = json.loads(ctl('j/devices'))['mice']
        expected_name = device_name.lower().replace(' ', '-')
        assert any(m['name'] == expected_name for m in mice), mice
        result['devices'] = mice

        def event(amount):
            pointer.send(5, 3, struct.pack('IIi', pointer.now(), 1, round(amount * 5 * 256)))
            pointer.send(5, 5, struct.pack('I', 0))
            pointer.send(5, 4)
            pointer.sync()
            time.sleep(.15)

        if locked:
            sender = subprocess.Popen([str(keys), '--hold', '1600', 'super'], env=env, stdout=subprocess.DEVNULL)
            time.sleep(.3)
            event(3)
            event(3)
            sender.wait(timeout=4)
            assert sender.returncode == 0
            result['passed'] = True
            return result

        assert ctl('dispatch hl.dsp.layout("pan-end")').strip() == 'ok'
        time.sleep(1)
        assert not overview()
        event(3)
        assert not overview(), 'unmodified pointer entered overview'
        sender = subprocess.Popen([str(keys), '--hold', '2600', 'super'], env=env, stdout=subprocess.DEVNULL)
        time.sleep(.3)
        assert sender.poll() is None, 'key helper exited before holding Super'
        assert not overview(), 'Super press alone entered overview'
        event(0)
        assert not overview(), 'zero pointer delta entered overview'
        event(3)
        should_enter = device_name == 'InputPlumber Mouse'
        assert overview() == should_enter, 'first controller delta did not enter native overview (or generic mouse did)'
        event(3)
        assert overview() == should_enter, 'second delta toggled overview off'
        subprocess.run(['grim', '-o', 'WAYLAND-1', str(directory / 'controller-held.png')], env=env, check=True, timeout=10)
        sender.wait(timeout=5)
        assert sender.returncode == 0
        time.sleep(1)
        assert not overview(), 'public Super release did not finish overview'
        result.update(super_alone_ignored=True, zero_delta_ignored=True, first_delta_enters=should_enter,
                      repeated_delta_keeps_mode=True, release_finishes=True)

        assert ctl('dispatch hl.dsp.layout("overview")').strip() == 'ok'
        time.sleep(.5)
        event(3)
        assert overview(), 'ordinary wheel in an existing overview changed modes'
        assert ctl('dispatch hl.dsp.layout("pan-end")').strip() == 'ok'
        time.sleep(1)
        result['existing_overview_wheel_preserved'] = True
        assert ctl('eval hl.bind("SUPER + mouse:273", hl.dsp.window.drag())').strip() == 'ok'
        sender = subprocess.Popen([str(keys), '--hold', '2200', 'super'], env=env, stdout=subprocess.DEVNULL)
        time.sleep(.3)
        pointer.send(5, 2, struct.pack('III', pointer.now(), 273, 1))
        pointer.send(5, 4)
        pointer.sync()
        time.sleep(.2)
        event(3)
        assert not overview(), 'dragged window input entered overview'
        pointer.send(5, 2, struct.pack('III', pointer.now(), 273, 0))
        pointer.send(5, 4)
        pointer.sync()
        sender.wait(timeout=5)
        time.sleep(1)
        assert not overview()
        result.update(drag_did_not_enter=True, passed=True)
        return result
    finally:
        if sender is not None and sender.poll() is None:
            sender.wait(timeout=5)
        pointer.sock.close()
        (directory / ('controller-locked.json' if locked else 'controller-input.json')).write_text(json.dumps(result, indent=2) + '\n')
