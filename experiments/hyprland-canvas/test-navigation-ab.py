#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description='Two-minute private navigation A/B/A; not a physical frame-pacing benchmark.')
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--parent-instance', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--seconds', type=int, default=120, choices=range(20, 121))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
started = time.monotonic()
record = {'scope': 'private navigation diagnostic, not physical FPS', 'runs': [], 'completed': False}
for name, path in [('baseline', args.baseline), ('candidate', args.candidate), ('runner', Path(__file__)),
                   ('fixture', root / 'test-canvas-groups.py'), ('patch', root / 'whole-canvas-camera.patch')]:
    record[name + '_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
try:
    for name, binary in [('A', args.baseline), ('B', args.candidate), ('A-repeat', args.baseline)]:
        remaining = args.seconds - 10 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('test budget exhausted')
        run_started = time.monotonic()
        with (args.output / (name + '.log')).open('w') as log:
            process = subprocess.Popen([sys.executable, str(root / 'test-canvas-groups.py'), '--quick-navigation',
                                        '--binary', str(binary.resolve()), '--parent-instance', str(args.parent_instance.resolve()),
                                        '--output', str(args.output / name)], stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            if code:
                raise subprocess.CalledProcessError(code, process.args)
        result = json.loads((args.output / name / 'quick-navigation.json').read_text())
        record['runs'].append({'name': name, 'seconds': time.monotonic() - run_started, 'result': result})
        print(name + ' complete', flush=True)
    record['completed'] = True
finally:
    record['seconds'] = time.monotonic() - started
    (args.output / 'result.json').write_text(json.dumps(record, indent=2))
