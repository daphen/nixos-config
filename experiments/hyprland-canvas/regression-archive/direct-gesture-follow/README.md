# Direct gesture following — reject as a standalone fix

2026-09-22. David requested a broader normal-panning test using short
three-finger swipes or Super+H/J/K/L. Removing the spring during swipes
eliminates tracking lag but produces much bigger position jumps at the current
input gain. It does not change the keyboard path. Do not activate this candidate
as a general smoothness fix. The desktop, canonical patch and sibling candidate
are unchanged.

## Exact source and candidate

Native HEAD `12f3780fae50a2edf8c50587bd052e95b8bfe652` plus control patch
`552b8e9b689295c4ff815ff190a24b1595bf25d2e68e2807a47c4f36d7eb3e4b`. Control ELF
`adc96bf4faf051a67e3f1aeca76f84e965f5081bba10365a04f2e85109e29a26`.

The archived patch warps X/Y to the existing computed goals on nonzero normal
pan deltas. It preserves gain, magnetism, overview and release centering. It
also preserves fractional camera offsets while panning: otherwise stopping the
animation would activate the existing idle pixel-rounding path. No new API,
state mirror, configuration flag or header change.

- Candidate-only patch SHA256:
  `5ed73226451caf8afffab222e2ddde25f8cbdb5e96c8a079b1a70a2353b634be`.
- Full candidate source patch:
  `818e18bfac632cc9571ed9e18e8a603829a86095cce704da6f8d5fbc19d1c77b`.
- Candidate ELF:
  `f7c8e1a7fd45a0f8a7e129860646de3bb2501f5ef135c7a9ac13312e4c2575d5`.
- Unchanged live ELF:
  `f4e0133886b890427487bd4f594b8bfb7988779bc6af97eebd012dda401e48b9`.

Candidate and restoration were warm incremental builds of Monitor.cpp plus
relink in the existing persistent cache. Independent copies preserved binaries.
Source/build were restored to exact control hashes before comparisons.

## Real input and verified paths

A temporary probe on the live layout dispatcher recorded 300 camera commands: 16
normal swipes, 238 pan deltas and 30 H/J/K/L focus commands. No overview
requests occurred. Swipes lasted 50–128 ms (median about 79 ms). Raw requested
travel after the existing 8× gain ranged from 1,754 to 8,262 logical pixels,
median 2,980 pixels per swipe, before magnetic adjustment.

Swipe path: Lua gesture callback → gain 8 → pan-begin/pan deltas/pan-end →
canvasPan spring goals → animated view. Keyboard path: focus direction →
canvasDirection → canvasCenter. It does not use canvasPan in normal mode, so
removing swipe spring-following cannot fix both reported interactions.

The recording was replayed with its original command timing and pauses through
the public layout dispatcher, after gesture recognition/gain, not as synthetic
hardware input. Real finger-to-display latency was not measured. A four-window,
two-row fixture allowed all H/J/K/L directions; it was not a clone of David's
real workspace geometry.

## Visible test was not representative

Only the old/control build was shown. David reported it looked substantially
worse than his actual desktop. The nested window's moving submission intervals
had median 8.36 ms, p95 30.03 ms, maximum 40.33 ms. It was therefore rejected as
a visual proxy for real Canvas. No direct-following candidate was shown there.

The machine was then on battery, `quiet` profile, only eDP-1 at 120 Hz and scale
1.6666666; earlier frame-sampling tests used AC and an external output as well.
Do not compare performance numbers across those conditions or attribute the
nested test's extra choppiness to the production camera.

The first runner also incorrectly rejected focus-state xdg_toplevel configures
as resize events. All measured sizes remained 644×668. The replay path now
allows activation configures while asserting sizes remain among the initial
sizes.

## Off-screen control → candidate → control

After the visual rejection, no further visible replays were run. Three headless
response checks used identical recorded input, 1296×720 at scale 1, the
production config, four real GTK clients and temporary render-coordinate probes.
All three passed, retained zoom 1, issued the same 80 focus-state configures,
and produced identical settled screenshots. Input scheduling p95 lateness was
0.35 / 0.62 / 0.32 ms; maximum 0.82 / 1.63 / 0.83 ms. Trace buffers did not
overrun.

Medians across the sixteen gestures, in logical pixels:

| Response measure                           | Control before | Direct | Control after |
| ------------------------------------------ | -------------: | -----: | ------------: |
| Median goal-to-view distance during swipe  |           1451 |      0 |          1439 |
| Largest step between render samples        |            267 |    616 |           268 |
| Moving samples during 250 ms after release |             29 |     29 |            29 |
| Keyboard median travel per moving interval |         671.58 | 671.49 |        671.64 |

Removing lag is expected by construction; it is not proof of smoother motion.
The roughly 2.3× larger steps are an adverse response trade-off. Release
animation remained present, final images matched, and keyboard behavior stayed
effectively unchanged. CPU over the 53.6-second replay was 2010 / 3660 / 1910
ms; GPU busy time 1112 / 1092 / 1158 ms. No CPU or GPU improvement is
established.

These are **headless camera-response samples**, not presented frames, real pixel
trajectories, measured physical FPS or a subjective result. The original replay
runner's frame-measurement text still said "fixed 120-command pan workload" in
these three records; the immutable input and 300 recorded dispatch timestamps
establish the actual workload. That label was corrected afterward and the
updated runner separately smoke-tested through its public entry point.

## Evidence and conclusion

Artifacts: `~/.cache/hyprland-canvas-dev/gesture-follow/`, including
`input.json`, `input-trace.txt`, `capture-meta.json`,
`response-comparison.json`, diagnostic scripts, independent binaries and the
three headless run directories. The failed visible control is retained
separately as `control-visible-failed/`.

The result rejects simply removing the spring at today's gain. It supports
investigating the combination of gesture gain and motion response, separately
from keyboard travel, but does not prove that another gain or curve will feel
better. Do not use the choppy nested fixture to claim a desktop improvement.
