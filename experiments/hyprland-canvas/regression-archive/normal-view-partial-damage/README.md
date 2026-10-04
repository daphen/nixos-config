# Normal-view partial-damage experiment — 2026-09-22

**Result: demonstrated less full-monitor invalidation work for settled content updates; no established scrolling or resize timing improvement. Keep this candidate experimental.**

`candidate.patch` is a 27-insertion, 1-deletion Renderer.cpp experiment on top of the current canonical canvas patch. It is deliberately NOT included in `whole-canvas-camera.patch`. The warm source was restored to the canonical patch after testing, so a subsequent ordinary dev build will not accidentally publish the experiment.

## What changed

At zoom 1 with the camera and workspace animations settled, ordinary tiled main-surface damage is translated into output pixels instead of invalidating the entire monitor. Fractional translation gets a one-pixel margin. Camera movement, overview, window animations, floating windows, effects and unknown surfaces retain full-redraw fallbacks. Generic box damage conservatively invalidates the whole monitor in the new partial-damage mode. Existing occlusion simplification remains disabled for the canvas.

This targets content updates with a stationary camera. It does not attempt to accelerate camera panning or animated resizing.

## Verified result

The corrected public-entry runner tested both binaries serially, using three repetitions at scale 1 and one at scale 1.5. All **96 workload trials** passed. All **six candidate settled-image comparisons** were pixel-identical to the matched control. Resize still produced eight configure events and eight commits per trial. Parent binary checks and cleanup checks passed.

Explicit full-monitor invalidations during each tiny-update trial:

| Phase | Control | Candidate |
| --- | --- | --- |
| Normal, scale 1, repetitions 2 and 3 | 10 each | 0 each |
| Returned to normal, scale 1, all 3 repetitions | 10 each | 0 each |
| Returned to normal, scale 1.5 | 10 | 0 |
| Overview, both scales | 20 each | 20 each |

Do not omit the startup outliers: the first normal trial recorded 68 candidate invalidations versus 10 control at scale 1, and 70 versus 10 at scale 1.5. The claimed reduction is for the settled path, not startup. Counts are calls to native `damageMonitor`, not pixel-fill measurements or physical presentation times.

Some candidate trials submitted fewer nested frames. Both binaries still committed the client updates, and lossless damage-triggered recordings passed the freshness and pixel checks. Do not translate this into an FPS gain. GPU timing was noisy even for the unchanged overview path, and these runs enabled debug logging. Neither the moving-camera nor resizing workloads establish a timing improvement.

`results.json` contains the reduced result table. Full logs, images, binaries and complete results remain in `/home/daphen/.cache/canvas-normal-damage-20260922/verified-{control,candidate}-{1,1.5}x/` and its parent directory.

## Benchmark fixes

- `pan-end` starts an animated commit; immediately calling `pan-begin` cancels the flag that eventually clears overview. The runner now allows that exit animation to finish before beginning the next mode. Earlier returned-to-normal results were not valid evidence for that mode.
- `--log-damage` enables both native damage logging and stdout logging with logging globally enabled. Tiny-update trials require a surface-damage log entry, preventing disabled logging from masquerading as zero invalidations.
- References must use the identical runner, fixtures, configuration, scale, repetitions and logging mode.

The original candidate popup run timed out during nested startup. The matched control passed, and the unchanged candidate passed on repetition, including tiled and floating popup placement with zero horizontal error. This was not established as a candidate regression; popup placement checks do not certify every popup repaint case.

## Provenance

- Repository HEAD: `fcc8ee42308f275444eedbd92b0904271603981b` (dirty working tree).
- Pinned upstream: `f05d73f35795ded80d7e1264a37e41b461625f9f`.
- Canonical/control full source patch SHA256: `61dbcffdc2d1eaa6502ce18791d8f985f0bc49ddeca75600e13773933dbe72e1`.
- Candidate full source patch SHA256: `27a06017c7a439c513c35b971a8d90f00bc5c0df9ffbd9f16f048ad8e4f1f9ee`.
- Candidate-only patch SHA256: `17d8ba8c674b0a522b15f79513b0584b84dba08490de9cc258facd717a0d986d`.
- Tested candidate binary SHA256: `e0922798389a78216cb34c7865a2833c9c7d7e0e710d0da4a088e2995da8fbeb`.
- Tested matched control binary SHA256: `e99cea537a5707011f45e58197600faed41648cdc1fffcf592242a570307b2fc`.
- Corrected runner SHA256: `b93166c787e1bec30315a4d6f7c5b374f26b498b12d8e7e81545cc7c0ece8f98`.

Both builds were warm incremental builds using `dev build --no-publish`, not cold builds. The initial candidate build also compiled two previously stale, pre-existing source edits (Monitor.cpp and X11Backend.cpp). The matched control was therefore rebuilt from the same source, differing only in Renderer.cpp; it is not a mislabeled copy of the running desktop binary. The canonical patch, validated install and running desktop were not replaced.
