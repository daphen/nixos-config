# Frame-aligned camera sampling — tested, not activated

2026-09-22: a visible control → candidate → control test found smaller
occasional camera-step errors, but little change to typical movement. This is a
candidate for a separately approved main-desktop trial, not a proven
physical-display fix. The normal development source and binary were restored to
the sibling-sync candidate. `whole-canvas-camera.patch` and the running desktop
are unchanged.

## Change and exact versions

`candidate.patch` adds four lines to `Renderer.cpp`. While a normal Canvas
camera is animating, the existing `resetTickState` makes the immediately
following `frameTick` sample freshly instead of observing the sub-1-ms throttle.
The existing animation timer remains in use. No new API, state cache, protocol,
or runtime flag.

- Native HEAD: `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Control source patch:
  `552b8e9b689295c4ff815ff190a24b1595bf25d2e68e2807a47c4f36d7eb3e4b`.
- Control ELF:
  `adc96bf4faf051a67e3f1aeca76f84e965f5081bba10365a04f2e85109e29a26`.
- Candidate is that source plus this patch, SHA256
  `c2d6f5837d6d1a6ee2f8b18b260de91993274c9678e1c5d1a39d6e1cb9f68f22`.
- Candidate ELF:
  `30624402d77aaf6a38eea94c1bac2db8a7399ceca09123a4d46f8a7f085b6cce`.
- Unchanged running ELF:
  `f4e0133886b890427487bd4f594b8bfb7988779bc6af97eebd012dda401e48b9`.

Both test variants include the saved sibling-sync changes; only camera sampling
differs. Both builds were warm incremental: one implementation unit plus relink,
using the existing persistent cache. The linker rewrites its output in place:
**use independent copies, not hard links, to preserve control binaries**. The
control was rebuilt back to its exact original hash before the valid comparison.

## Valid comparison

The existing real-window runner used four GTK clients, 1296×720 at scale 1, 120
Hz nested output, three two-second pans in each of normal, overview and
returned-normal modes. Each pan sends 120 sine-wave delta commands at 60 Hz, 80
logical-pixel amplitude. No client configures occurred during pans.

Temporary probes recorded actual animation ticks, camera coordinates immediately
after the renderer's frameTick, and the nested output's actual wl_surface
commits. Probe addresses came from each exact ELF; the monitored register and
field layout were checked. Probes and trace instances were removed. No trace
buffers overran.

Analysis retains 0.35–1.90 seconds of each pan. It compares each movement step
with the surrounding seven-step mean, excluding slow turning points below 80
logical pixels/second. Values below are medians of the six
normal/returned-normal trial statistics, not pooled-frame confidence intervals.

| Measure                                | Control before | Candidate | Control after |
| -------------------------------------- | -------------: | --------: | ------------: |
| Camera sample age p95                  |       0.833 ms | 0.0205 ms |      0.972 ms |
| Larger step deviation, p95             |         16.23% |    10.47% |        20.38% |
| Typical step deviation, median         |          6.30% |     6.21% |         7.46% |
| Timestamp-adjusted speed deviation p95 |         13.41% |    11.92% |        20.92% |
| Submission gap p95                     |       8.706 ms |  8.863 ms |      8.857 ms |
| Gaps over 12.5 ms, retained frames     |         1/1116 |    0/1115 |        0/1116 |
| GPU busy time per submitted frame      |      0.1344 ms | 0.1353 ms |     0.1387 ms |
| CPU time per submitted frame           |      0.6534 ms | 0.9765 ms |     0.9386 ms |

The larger-step statistic improved 35–49% relative to the two control runs;
typical steps changed little. CPU varied substantially in the untouched overview
mode too (0.650 / 0.903 / 1.011 ms per frame), so this does not establish a CPU
improvement or regression. GPU cost stayed similar. Candidate and final control
matched all three settled reference images exactly; no extra long submission
gaps appeared in the candidate.

These are camera coordinates in **submitted nested frames**, not measured
physical pixel trajectories, presentation latency, or a subjective smoothness
verdict. The experiment did not test external/mixed-scale output behavior.

## Fixture correction and retained evidence

An initial run exposed nondeterministic 15-second native startup warning banners
in the screenshot. The runner now waits 16 seconds after clients initialize,
before any measured workload, and records monotonic measurement intervals. All
three runs were repeated after that correction; earlier startup-contaminated
runs are not included above. A prior root-to-user launcher environment mistake
was also corrected before measured runs; normal user cursor paths were restored.

Evidence and independent binaries are in
`~/.cache/hyprland-canvas-dev/frame-sampling/`: `comparison.json`,
`comparison.log`, `analyze.py`, `run-probed.py`, `Hyprland.control`,
`Hyprland.candidate`, and the `control-before/`, `candidate/`, `control-after/`
directories. Each includes raw trace, probe metadata, runner result and
screenshots. `git apply --check` succeeds for this patch against the restored
sibling-sync source.
