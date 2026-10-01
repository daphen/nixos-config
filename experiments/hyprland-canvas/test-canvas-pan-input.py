#!/usr/bin/env python3
"""Drive finger-source Wayland axis input and the public Super release binding."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import socket
import struct
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--instance', type=Path, required=True)
parser.add_argument('--keys', type=Path, required=True)
parser.add_argument('--directory', type=Path, required=True)
args = parser.parse_args()


def ctl(command):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(args.instance / '.socket.sock'))
        connection.sendall(command.encode())
        result = b''
        while chunk := connection.recv(65536):
            result += chunk
    return result.decode()


def geometry():
    return sorted((w['title'], w['at'], w['size'], w['floating']) for w in json.loads(ctl('j/clients')))


def capture(name):
    path = args.directory / ('pan-' + name + '.png')
    subprocess.run(['grim', '-o', 'WAYLAND-1', str(path)], check=True, capture_output=True, timeout=10)
    return hashlib.sha256(path.read_bytes()).hexdigest()


pointer_path = Path(__file__).with_name('test-canvas-x11-input.py')
spec = importlib.util.spec_from_file_location('pointer_fixture', pointer_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
pointer = module.Pointer(Path(os.environ['XDG_RUNTIME_DIR']) / os.environ['WAYLAND_DISPLAY'])
result = {'passed': False, 'input': 'zwlr_virtual_pointer_v1 axis_source=finger, horizontal axis; Super+Tab entry and Super release',
          'hardware': 'No physical PC touchpad or Steam Deck device was exercised.',
          'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'pointer_helper_sha256': hashlib.sha256(pointer_path.read_bytes()).hexdigest()}
sender = None
try:
    assert ctl('dispatch hl.dsp.layout("pan-end")').strip() == 'ok'
    time.sleep(1)
    initial = geometry()
    sender = subprocess.Popen([str(args.keys), '--hold', '4600', 'super+tab'], stdout=subprocess.DEVNULL)
    time.sleep(1.1)
    pointer.move(640, 360)
    before = capture('before-finger-axis')
    previous, start = 0.0, time.monotonic()
    for n in range(90):
        time.sleep(max(0, start + n / 60 - time.monotonic()))
        x = 80 * math.sin(2 * math.pi * (n + 1) / 90)
        pointer.send(5, 3, struct.pack('IIi', pointer.now(), 1, round((x - previous) / 2.5 * 256)))
        pointer.send(5, 5, struct.pack('I', 1))
        pointer.send(5, 4)
        pointer.sync()
        previous = x
        if n == 22:
            during = capture('during-finger-axis')
    pointer.send(5, 6, struct.pack('II', pointer.now(), 1))
    pointer.send(5, 4)
    pointer.sync()
    sender.wait(timeout=6)
    assert sender.returncode == 0
    time.sleep(1)
    returned = capture('release-settled')
    assert geometry() == initial, 'finger-axis panning changed tiled geometry'
    assert before != during and during != returned, 'finger input did not visibly pan and settle'
    focused = json.loads(ctl('j/activewindow'))
    titles = ['Editor / canvas.cpp', 'Notes / visual language', 'Browser / project', 'Terminal / build']
    keyfile = args.directory / ('app' + str(titles.index(focused['title']))) / 'keys'
    keys_before = keyfile.read_text().splitlines() if keyfile.exists() else []
    subprocess.run(['wtype', 'x'], check=True, capture_output=True, timeout=5)
    time.sleep(.2)
    assert keyfile.read_text().splitlines() == keys_before + ['120'], 'settled selection did not receive keyboard input'
    assert not ctl('configerrors').strip()
    result.update(passed=True, focus=focused['title'], geometry_preserved=True, captures={'before': before, 'during': during, 'returned': returned})
finally:
    if sender is not None:
        sender.wait(timeout=6)
    pointer.sock.close()
    (args.directory / 'pan-input.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
