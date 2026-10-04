#!/usr/bin/env python3
"""Measure horizontal camera travel from the fixture's amber title-bar stripe."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
parser.add_argument('--ffmpeg', required=True)
args = parser.parse_args()
data = json.loads((args.directory / 'result.json').read_text())
assert data['passed'] and data['scale'] == 1
results = {}
for run in data['runs']:
    scenario = next(s for s in run['focus_scenarios'] if s['mode'] == 'normal')
    movie = args.directory / run['name'] / 'normal.mkv'
    pts = json.loads(subprocess.check_output([str(Path(args.ffmpeg).with_name('ffprobe')), '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'json', str(movie)]))['frames']
    times = scenario['video_frames']
    assert all(abs(float(frame['pts_time']) - (times[n] - times[0])) < .003 for n, frame in enumerate(pts))
    notes = next(window for window in run['initial_geometry'] if window[0].startswith('Notes'))
    editor = next(window for window in run['initial_geometry'] if window[0].startswith('Editor'))
    stripe_y = notes[1][1] + 56
    raw = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(movie), '-vf', f'crop=1440:1:0:{stripe_y}', '-fps_mode', 'passthrough', '-enc_time_base', '1:1000000', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'])
    width = 1440 * 3
    assert len(raw) == len(pts) * width
    rows = []
    for n in range(len(pts)):
        line = raw[n * width:(n + 1) * width]
        start = line.find(bytes([230, 179, 102]) * 8)
        if start >= 0 and times[n] < scenario['key_times'][1]:
            rows.append({'t_ms': (times[n] - scenario['key_times'][0]) * 1000, 'x': start // 3, 'frame': n})
    origin, target = rows[0]['x'], rows[-1]['x']
    distance = origin - target
    assert distance == notes[1][0] - editor[1][0] and distance > 0, (distance, notes, editor)
    for row in rows:
        row['progress'] = (origin - row['x']) / distance
    speeds = [(a['x'] - b['x']) / ((b['t_ms'] - a['t_ms']) / 1000) for a, b in zip(rows, rows[1:]) if a['t_ms'] >= 0]
    metrics = {f't{percent}_ms': next(row['t_ms'] for row in rows if row['progress'] >= percent / 100) for percent in (50, 90, 99)}
    metrics.update(distance_px=distance, peak_speed_px_s=max(speeds), first_motion_ms=next(row['t_ms'] for row in rows if row['progress'] > 0))
    metrics['focus_observation_delay_ms'] = [(change['time'] - key) * 1000 for change, key in zip(scenario['trials'][0]['focus_changes'], scenario['key_times'])]
    results[run['name']] = {'metrics': metrics, 'frames': rows}
    print(run['name'], json.dumps(metrics))
(args.directory / 'trajectory.json').write_text(json.dumps(results, indent=2) + '\n')
