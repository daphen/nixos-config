# Normal-view translation-aware occlusion — 2026-09-22

Accepted and activated on 2026-09-22 at the user's request. The running and
validated binaries now match the tested candidate hash below. Activation record:
`~/.cache/canvas-occlusion-20260922/activation/restart-result.json`; previous
binary preserved as `activation/Hyprland-before` under the same root. The clean
launcher restart produced PID 106147, a responsive internal display, and no
configuration errors. No rebuild was needed: the exact tested executable was
atomically installed. The earlier benchmark is a synthetic real-window
comparison, not a Cockpit interaction-latency or physical-presentation
benchmark.

## Production change and ownership

The existing render-pass simplifier owns visibility and opaque-region planning.
It associates each element with its renderer-hint transform in one forward walk,
then evaluates bounds and opaque coverage in output coordinates during its
existing reverse walk. Conservative one-pixel bounds/opaque margins protect
fractional edges. Unsupported transforms and transformed blur keep the old
unsimplified path. Effects retain their existing disableSimplification checks.

The renderer permits this only for normal Canvas translation at zoom 1, outside
overview, commit mode, and zoom animation. Full-monitor Canvas damage is
retained. No header, protocol, persistent cache, layout behavior, or resize
behavior changed. The initial duplicate transform walks were consolidated inside
simplify(), not split into new utility functions.

## Provenance

- Source base: `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Baseline full patch:
  `a4546b59e69522a530dfab4f74f6f4bfd056ea273f593fd613414edc0b49ba9b`.
- Candidate full patch, now exported to `whole-canvas-camera.patch`:
  `e28bd00f477569883174885f7dfd916d1088245e5aba6bec22592d28b361db2f`.
- Baseline binary:
  `c0a395955d988eaac8a31a6de11330a4aa29080ac12547fd82c3879191a1d7ad`.
- Candidate binary:
  `3bcddd41ed5075dd18c18f13ae135f626c5947c39fbceb2369b10ce7c4989d7f`.
- Candidate executable:
  `~/.cache/canvas-occlusion-20260922/Hyprland-refactored`.
- Build: warm incremental, two implementation files initially, then one after
  consolidation. No cold bootstrap or header invalidation. Publishing and
  restart happened only after the user requested the build trial.
- Source `git diff --check` and reverse application of the exported patch
  passed. Outer-repository whitespace checks on this patch-as-data can flag its
  literal blank context lines; those are not source whitespace defects.

## Visible acceptance comparison

The user explicitly requested an on-screen comparison after the offscreen work.
At that point the external monitor had been disconnected. The active physical
output was eDP-1, 3840×2400 at scale 1.6666666. The test window fit below its
bar: **2295×1380 nested framebuffer at 1.6666666**, approximately 3825×2300
physical pixels on the host. This is not a native 4K nested framebuffer.

Control → candidate → control ran visibly on that desktop, with three pan
replays per mode. Median GPU busy milliseconds per submitted frame:

| View               | Control before | Candidate | Control after |
| ------------------ | -------------: | --------: | ------------: |
| Normal             |         0.7733 |    0.4601 |        0.7698 |
| Overview           |         0.7287 |    0.6837 |        0.7366 |
| Returned to normal |         0.7570 |    0.4747 |        0.7834 |

Normal-view GPU savings are **40%**, returned-normal savings **37–39%**. Every
candidate normal/returned-normal trial was below every corresponding control
trial. Submitted frame counts did not fall (candidate normal 275–279, controls
269–273; candidate returned-normal 276–277, controls 266–276). Overview retains
its fallback; claim no architectural overview improvement. CPU time did not
consistently improve: normal candidate ~0.76 ms/frame versus ~0.63–0.70 for
controls; returned-normal ~0.61 versus ~0.62–0.63. This is a GPU/CPU tradeoff,
not a claim of 40% faster desktop interaction.

All candidate and repeated-control screenshots matched exactly in all three
views. All processes cleaned up and the live binary stayed unchanged. These
visible results, rather than the offscreen estimates, support keeping the
candidate. The adjacent `visible-*.json` files are the raw acceptance records;
full logs/screenshots are under
`~/.cache/canvas-occlusion-20260922/visible-internal-{control,candidate,control-repeat}/`.
The fixture is opaque GTK windows over wallpaper, not a measurement of the
running Cockpit's own rendering workload. Final acceptance omits video
recording; earlier smaller-output damage-driven checks are documented below.

## Earlier offscreen comparison

`test-canvas-occlusion.py` runs control → candidate → control inside a private
GPU-backed headless compositor. A mapped nested child receives frame callbacks
without placing windows over the physical desktop. Its parent stays the same
baseline binary for all three runs. Each run uses four real GTK windows over a
wallpaper, three two-second sinusoidal pan replays per mode, and settled output
screenshots. No video recording runs during timing.

Final resolution: **3840×2160 at scale 1.5**, requested refresh 120 Hz. Raw
artifacts: `~/.cache/canvas-occlusion-20260922/final-4k/`. The adjacent JSON
files preserve the full run records and exact input hashes.

Median GPU busy milliseconds per submitted child surface commit:

| View               | Control before | Candidate | Control after |
| ------------------ | -------------: | --------: | ------------: |
| Normal             |         2.8468 |    1.9594 |        2.0706 |
| Overview           |         2.1172 |    1.9765 |        1.6718 |
| Returned to normal |         2.7624 |    1.3517 |        2.0390 |

Returned-normal savings are 34–51%; every candidate trial in that mode was below
every control trial. Initial normal-view savings are 5–31% and noisier. Overview
is an unchanged fallback and varies between control runs; claim no overview
gain. Returned-normal CPU cost was approximately 0.64 ms/commit versus 0.62
ms/commit. Submitted commit counts are retained in JSON so fewer frames cannot
masquerade as cheaper frames. These are not physical FPS, missed-vblank, or
input-latency measurements. The absolute GPU saving is about 0.7–1.4 ms per
returned-normal submitted frame in this fixture, not a promised percentage
improvement to the whole desktop.

All three candidate screenshots and the repeated control screenshots matched
exactly: **zero differing pixels**. The final 4K run checks panning cost and
settled pixels only, explicitly `freshness_checked: false`.

Earlier smaller-output runs of this same candidate binary passed damage-driven
small-update recordings and exact settled-image comparisons at scales 1 and 1.5:
`settled-refactored/`, `settled-refactored15/`, and the earlier
`reusable-scale*` artifacts under the same cache root. Full-resolution lossless
recording dropped updates even on the baseline; it was not counted as a passed
4K freshness test. Recording-based timing and the temporary GTK frame-callback
observer were not accepted evidence. The observer was removed; the GTK fixture
has no new probe.

## Reproduction

Requires Python, GTK from the existing fixture, swaybg, grim, wf-recorder, and
ffmpeg. No NumPy or unit-test framework is required. Supply the current live
parent instance explicitly; the driver hides and disables its bootstrap output.

```sh
python3 experiments/hyprland-canvas/test-canvas-occlusion.py \
  --baseline /path/to/Hyprland-control \
  --candidate /path/to/Hyprland-refactored \
  --parent-instance /run/user/1000/hypr/CURRENT_INSTANCE \
  --output /path/to/new-results \
  --ffmpeg /path/to/ffmpeg \
  --wallpaper /path/to/wallpaper.png \
  --size 3840 2160 --scale 1.5
```

The driver supplies a headless parent and does not expose windows on the working
desktop. The underlying runner's `--visible` can also use a physical parent, but
requires explicit permission; that is how the final visible comparison ran.
`--pan-only` selects cost and settled-image checks, not the separate
damage-recording checks. Full-resolution video encoding is deliberately not part
of this performance acceptance run.

## Resize-content status

Design only, not implemented by this candidate. The existing window-effects
lifecycle should own a single pending/active resize transition; layout requests
geometry, the Wayland commit boundary determines when new content is ready, and
the renderer owns local main-pass capture/composition. The read-only design is
at `~/.cache/canvas-external-20260922/resize-design.md`; it is a proposal, not
verified resize behavior. A local snapshot API is preferable to monitor-sized
captures or temporary mutations of window geometry.
