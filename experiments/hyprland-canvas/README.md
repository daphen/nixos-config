# Hyprland canvas experiment

The shipping package remains `nix build path:.`. Its only Hyprland source change
is `whole-canvas-camera.patch`; the Aquamarine nested-configure patch is applied
independently by the overlay.

## Staged PhantOMat visual palette

The [eight-control Tune the Look palette](PHANTOMAT-TUNING.md) is implemented
and verified in isolated real compositors at 1× and 1.25×, including saved
settings, actual keyboard-focus restoration and idle/render cost. It builds on
[the previous visual/focus slice](PHANTOMAT-EVALUATION.md). Nothing is
activated; the warm native source contains the staged candidate, so do not
publish it incidentally through an unrelated build. The live config and
validated binary are unchanged.

## Commit-timed resize candidate

The patch now retains the old picture during a normal tiled Wayland resize, then
animates and crossfades when the app's new size is actually committed. A 300 ms
deadline releases stalled apps back to native behavior. Pointer drags,
floating/fullscreen windows and X11 retain their existing resize behavior.

The [visible verification](regression-archive/commit-timed-resize/README.md)
passed 18 real-window cases, including translucent clients, delayed redraw,
rapid retargeting and close-during-wait. The initial per-window build was
activated with approval on 2026-09-22. A newer candidate also coordinates tiled
siblings: measured gap variation fell from 21 pixels to 1 at 100% scale (2 at
167% scale). It is exported but awaits activation. No frame-time improvement is
claimed.

## Incremental camera loop

```bash
./dev bootstrap                         # once: pinned source + Ninja full build
$EDITOR ~/.cache/hyprland-canvas-dev/source/src/render/Renderer.cpp
./dev build                             # changed translation units + validation
./dev build --no-publish                # compile a trial without replacing the validated package
./dev export                            # source diff -> canonical shipping patch
```

`dev` enters the flake's shell itself. The shell inherits the overlay package's
exact build inputs and compiler, including the patched Aquamarine. Source, Ninja
state, and the last config-validated install persist under
`$XDG_CACHE_HOME/hyprland-canvas-dev/` (default `~/.cache/`).

`./dev export` emits a stable full-index diff from the locked Hyprland source.
`./dev sync` refuses a dirty source; after exporting or saving work elsewhere,
`./dev sync --force` resets it and reapplies the checked-in patch.

The Home Manager `hypr-session` wrapper passes the exact system Canvas store
package to `run-login --real --system`; this is the production next-login path.
Direct `run-login` remains the explicit validated-dev path, while
`run-login --stable` retains the cached Nix fallback for recovery. No launcher
rewrites a live package symlink.

On this machine, touching only `src/render/Renderer.cpp` and running
`./dev build` took **47.226 seconds** including relink, config verification, and
publishing the validated package.

## Rendering baselines before changing the compositor

`test-canvas-rendering.py` reuses the archived GTK resize fixture, loads the
production Lua config with startup services and the random splash motto
suppressed, and starts an isolated nested compositor. It temporarily places the
`aquamarine` test window on a hidden special workspace; it does not restart or
reconfigure the visible compositor apart from that temporary window rule. Run
instances **serially**: the parent rule matches the nested backend's shared app
ID.

```bash
python3 experiments/hyprland-canvas/test-canvas-rendering.py \
  --binary /path/to/Hyprland \
  --parent-instance /run/user/1000/hypr/EXACT-LIVE-INSTANCE \
  --ffmpeg /path/to/ffmpeg \
  --output "$HOME/.cache/canvas-baseline-1x" --scale 1 --repeats 3
```

Requires Python, the existing fixture's GTK library, `wf-recorder`, FFmpeg, and
readable per-process DRM graphics-engine counters. Output directories must be
new. The parent instance is the directory containing its `hyprland.lock`; do not
select an unrelated nested compositor. Repeat at `--scale 1.5`. Repeat the same
build with `--reference /path/to/baseline` before comparing a candidate: this
verifies that settled images are reproducible rather than timing noise.

Use `--log-damage` on both builds to count native surface-damage events and
full-monitor invalidations. These are invalidation requests, not pixel-fill or
FPS measurements; logging also affects the timing samples. The runner waits for
the overview-exit animation before starting another pan: starting a pan
immediately cancels the commit that clears overview, invalidating the mode
label.

For normal, overview, and returned-to-normal views, the test records:

- Three trials each of idle, 24×24 client updates, a two-second pan replay, and
  eight alternating resize actions. GPU engine time, CPU time, submitted nested
  frames and client configure/commit counts are retained. Resize must issue
  exactly eight configure events and eight client commits; non-resize workloads
  must issue no configures.
- Damage-triggered, lossless recordings **outside** the cost measurements. Both
  marker colors and at least ten pixel changes must appear; updates must remain
  localized. `--reference` requires exact settled-frame pixel matches in all
  three views.
- Exact binary, config, fixture, runner and canonical patch hashes, output
  geometry, parent output context, power profile and capture-tool versions.
  Changed inputs, a fixture stealing focus, and cleanup failures fail the run.

Ordinary `grim` screenshots force a full repaint and cannot establish partial
redraw correctness. These recordings use `copy_with_damage` after capture
startup. However, this Hyprland version reports full **capture-copy** damage
unconditionally (`ScreenshareFrame.cpp`); capture rectangles are deliberately
not interpreted as renderer repaint area. Freshness/pixel checks and cost
measurements are separate evidence.

### Translation-aware occlusion candidate

The
[2026-09-22 comparison](regression-archive/normal-translation-occlusion/README.md)
records the real-window A/B/A result, exact source/binary hashes, and
limitations. The candidate is exported in the source patch and was **activated
on 2026-09-22** after the user's requested trial. The running and validated
executable match the tested binary; the previous one is retained for rollback.
This changes panning occlusion, not resize presentation.

`test-canvas-occlusion.py` runs the existing window workloads inside a private
headless desktop, avoiding physical-desktop test windows. Use
`--size WIDTH HEIGHT` and `--scale` to describe the workload. Its `--pan-only`
child runs measure panning and compare settled screenshots; they do not claim to
validate small-update video freshness. A physical-parent `--visible` comparison
requires explicit user permission. The final acceptance comparison used that
permission.

### What constitutes a benefit

The initial same-binary repeat check found GPU-time medians varying from -49% to
+69% across these hidden workloads. These cost samples are **diagnostic, not a
performance acceptance gate**: even a 20% apparent gain here is insufficient.
Settled-pixel checks were exact at both tested scales.

Compare the same scale, fixture, workload and power conditions. Require a
repeatable CPU/GPU cost reduction larger than the baseline's run-to-run spread,
without losing client updates or worsening overview. A practical initial target
is at least 20%, not a few percent from one noisy sample. Inspect both total
work and work per submitted frame; dropping frames is not an optimization.

Hidden nested frames are parent-throttled. Their commit gaps are **not**
physical presentation times, FPS, or missed-vblank counts. These tests also do
not yet certify popup/transparency behavior, every intermediate zoom frame,
slow-client resize presentation, or Deck performance. Use the existing
popup/resize regressions and a controlled physical-output frame trace before
staging a candidate. No native build or renderer change is needed to run these
baselines.
