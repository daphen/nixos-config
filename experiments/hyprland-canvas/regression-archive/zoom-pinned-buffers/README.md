# Canvas capture-pool performance — verified local improvement

**Two native lines avoid repeated fallback rendering when overview snapshots
hold every work buffer.** In controlled sixteen-window zoom/pan tests, GPU work
per nested commit fell **9.20% pooled**, or **11.56% using the predeclared
run-median comparison**. The fix also restores an overview tile that the old
fallback left blank. Not deployed; no Deck battery or physical-presentation
claim.

## Production path and smallest fix

Starting repository HEAD: `515431b869612514845e4a79b8b77ce3e66e3d53`. Native
base: `12f3780fae50a2edf8c50587bd052e95b8bfe652` (pinned upstream
`f05d73f35795ded80d7e1264a37e41b461625f9f`).

Production gestures/keys use `hl.dispatch(hl.dsp.layout(...))`; controller
commands and this regression enter the public IPC `dispatch hl.dsp.layout(...)`
path. The existing Lua dispatcher/layout interception reaches
`CMonitor::canvasOverview`/`canvasPan`, native camera animations and monitor
damage, then `renderMonitor`, transformed-window rendering, and
`CMonitorResources::getUnusedWorkBuffer(size)`. GTK buffers use normal Wayland
configure/commit/frame callbacks. Real content damage changes the existing
capture content serial. Lock testing waits for the real session-lock `locked`
event; the renderer intentionally freezes captures after that handshake, rather
than accepting live content as a stale-read fix.

Already working: backdrop caching, capture content/size validation, camera
culling, and full cache clearing before leaving overview. The eight-window
animated probe had **zero buffer fallbacks**; the initial theory about
return-path pinned caches was disproved.

Reachable gap: with sixteen mapped windows in two rows, cached captures hold all
eight sized pool slots. A further visible capture falls back to the
monitor-sized path even though the existing pixel budget permits another buffer.
That path repeats work and can omit window content outside the monitor source
rectangle. The focused bottom-right tile in `baseline-missing-tile.png` contains
wallpaper inside its selection outline; `candidate-visible-tile.png` restores
its client content. Empty space on the right is camera framing, not the defect.

The only production change is in `MonitorResources.cpp`: allocate another sized
buffer when all existing buffers are caller-held. Preserve the existing
**64-megapixel allocation-budget checks**, eviction of unused buffers,
allocation-failure handling, image description, and unsized eight-buffer cap.
Reuse/reallocation still wins when any sized buffer is free. No header, new
cache, protocol, quality setting or runtime development flag changes. Existing
lock, late-client, missing-lock, inactive-gaming-workspace, input, freezer and
serialization defenses are unchanged.

## Controlled results

AC Proart, existing quiet profile, AMD Radeon 890M/radeonsi/Mesa 26.0.5. Same
private Weston GL → compatible Hyprland headless parent → measured nested child.
Fixed separate physical CPU cores: child 2, parent 0, bootstrap 1. Raw 800×1280,
transform 3, scale 1; nested monitor reports 60 Hz. Commit counts are **not
physical FPS**.

Lens strength `.035`, edge `1.11`, vignette `.85`, backdrop blur `.7`, parallax
`.06`, depth `.12` preserved. Every measured run has three warm-up cycles;
A/B/A/B, three trials × three round trips per run: **18 measured round trips per
binary per workload**. The pan workload includes eight 160-pixel camera steps in
each direction per round trip. The eight-window workload requests terminal-like
full-content updates every 16 ms through real GTK buffers; visible updates are
asserted.

| Workload / metric                                   | Baseline | Candidate |                      Change |
| --------------------------------------------------- | -------: | --------: | --------------------------: |
| 16 windows, zoom/pan GPU ms/commit, run-median mean | 0.854939 |  0.756151 |                 **−11.56%** |
| Same, pooled GPU ms/commit                          | 0.833804 |  0.757108 |                  **−9.20%** |
| Same, CPU ms/commit, run-median mean                | 0.442387 |  0.437465 | −1.11%, no useful CPU claim |
| 8 updating windows, GPU ms/commit                   | 0.551261 |  0.554245 |                      +0.54% |
| Same, CPU ms/commit                                 | 1.170635 |  1.176462 |                      +0.50% |

Predeclared acceptance: at least 5% improvement, exceeding twice the larger
same-binary run-median spread; no other mean/p95 resource regression above 5%
beyond that noise rule; visual/security regressions must pass. The
sixteen-window GPU difference is `0.098788 ms`, versus a noise threshold of
`0.009668 ms`. All gates pass. CPU totals use 10 ms accounting ticks; an
isolated control outlier makes pooled CPU savings misleading, so no CPU-speedup
claim is made. RSS high-water differs by less than 0.3% in these runs.

### Render tails and first entry

Separate instrumented A/B/A/B runs use the same native delta, two trials × two
pan round trips. `measurement-only.patch` records render/capture wall times;
**it is not included in the shipping patch or final executable**. Trial
timestamps exclude screenshots, lock checks and teardown from render-tail
statistics.

| Instrumented render wall time | Baseline A1 / A2 | Candidate B1 / B2 |
| ----------------------------- | ---------------: | ----------------: |
| Timed p95, ms                 |    0.794 / 0.824 |     0.706 / 0.842 |
| Timed p99, ms                 |    1.153 / 1.215 |     0.995 / 1.129 |
| Timed maximum, ms             |   22.697 / 2.885 |     2.505 / 2.308 |
| First-entry 800 ms p95, ms    |    0.619 / 0.761 |     1.055 / 0.827 |
| First-entry maximum, ms       |    4.226 / 4.417 |     4.391 / 4.092 |
| Timed capture fallbacks       |    2,830 / 2,828 |         **0 / 0** |

First-entry p95 is higher, but not beyond the predeclared same-binary noise
threshold; first-entry maxima remain around 4.1–4.4 ms. The one 22.7 ms control
tail did not reproduce in A2, so this is **not evidence that physical jank was
fixed**. The meaningful result is lower GPU work and elimination of the proven
fallback path. Raw commit-gap maxima also include deliberate settled waits of
about 600 ms; they must not be presented as render stalls.

## Public regressions

- Nine settled captures are byte-identical across all four eight-window runs:
  normal, returned, overview, pan, translucent client, optional
  chromatic/blur/feather, locked, locked during client updates, and locked after
  a late client maps. Early animated overview/pan snapshots are not
  deterministic and are not used as goldens.
- New public sixteen-window focused-tile assertion **fails the baseline** with
  wallpaper RGB `[0.180392, 0.231373, 0.290196]`, and **passes the candidate**
  with client RGB `[0.074510, 0.082353, 0.109804]`. This intentional correction
  is not compared against the old missing-window image as a golden.
- Candidate closes the selected window during overview, creates a second private
  output, moves a real client there, enters overview, acquires a real two-output
  session lock, verifies a late client cannot change locked output, and checks
  the missing-lock fallback after the lock process exits. The captured fallback
  was also inspected: native lock-crash warning, no application content.
- `test-deck-game-mode.py`: 15/15 mocked command tests pass. No live freezer,
  InputPlumber, or Deck test is claimed.

## Exact evidence and replay

`results.json` contains every final timing row, binary/config/harness hash,
capture hash, first-entry/tail summary, and lifecycle result. Raw logs, binaries
and replay scripts remain in `/home/daphen/.cache/canvas-zoom-round2/`
(`compare-pool.sh`, `profile-pool.sh`, `regress-pool.sh`). The first probe with
an incorrect Wayland timestamp parser failed and was excluded; the parser was
fixed before controlled comparisons.

- Native baseline diff:
  `9ee99e15979745e5816cdf04a61f48a6d2e61f253c8e9d961d91c65ec39a02f4`.
- Native final diff:
  `4970d945f3e19ff9bed00c22f901fa36ccccd67f67739cefe3de628e233821ad`.
- Final executable:
  `10c3bcd72f8db9c352bd27fbdb19d4763d8eea25b6e6b3b29fba4f4de356c7c9`.
- Final shipping patch:
  `f76dce4b2aee125cf61c88da18b28af5b6a835545f6d7b9c6e24b8429d690334`.

The shipping patch was applied to an isolated Git index at the native base and
its resulting tree verified as `f324de9916099aa65e32a993d2f929933d367219`; its
`MonitorResources.cpp` matches the measured native source exactly. Only this
two-line production seam differs from the original shipping patch.

All builds were **warm incremental**, using only the granted
`/home/daphen/.cache/hyprland-canvas-secure-lock/{source,build}`, two jobs and
`dev build --no-publish`: two CPP files for temporary profiling, one CPP for the
candidate, then two CPP files to remove profiling. No source duplication,
configure, clean, bootstrap, central-header rebuild, publication or live
activation. The validated binary and original Deck store binary retain their
original hashes. The Deck was never contacted or woken; no desktop, Cockpit,
agentd or Quickshell service was restarted.

Actual worker model: `openai/gpt-6-astra`, verified from
`PI_PROVIDER`/`PI_MODEL`. One bounded read-only Astra research child completed;
its suggested map-sweep optimization was not needed or shipped.
