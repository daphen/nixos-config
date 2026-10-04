# Normal-view partial damage — 2026-10-01

**Verified on the current dev source: small-update GPU cost fell 96.9%, into
stock Dwindle's range. Not activated.**

## Change and containment

Settled, zoom-1 tiled-window surface and window damage is translated into output
pixels, with a one-pixel margin for fractional translation. Camera/workspace
motion, overview, floating windows, transformed or animating windows, and
generic box damage retain full-monitor fallbacks. Existing canvas occlusion
behavior is unchanged.

The current dev renderer also had a backdrop element whose
`requiresFullDamage()` expanded the reduced region back to the whole output. Its
existing caller now skips backdrop preparation when overview reveal is zero.
Overview still uses the original backdrop path.

`current-source.patch` is the complete bounded delta against the pre-test
current renderer. It includes that backdrop caller change and passes a
reverse-apply check against the tested source. `whole-canvas-camera.patch`
contains the compatible partial-damage changes; its older renderer does not yet
contain the backdrop feature. No unrelated dev features were exported into the
shipping patch, and all other shipping diff blocks were preserved byte-for-byte.

## Matched three-way comparison

Same real GTK fixture, serial hidden Weston/Hyprland instances, 3840×2400 at 120
Hz, scale 1.6666666. Two runs per variant, in
canvas/stock/fixed/fixed/stock/canvas order. GPU timestamp query time per
second, not physical presentation time:

| Workload               | Stock Dwindle | Current canvas | Fixed canvas |
| ---------------------- | ------------: | -------------: | -----------: |
| Small moving rectangle |     9.66 ms/s |    269.26 ms/s |    8.44 ms/s |
| Full-window updates    |   133.28 ms/s |    268.73 ms/s |  142.66 ms/s |

Small-update cadence was approximately 120 submitted frames/s for all variants.
Full-update cadence was 115–117 frames/s. Full-update fixed GPU cost was
approximately 7% above stock, rather than a claim of identical performance. This
does not certify browser scrolling, physical-display pacing, or
overview/navigation smoothness.

The earlier damage-only and blur-filter candidates did not improve measured GPU
cost. The unnecessary backdrop pass was the missing final step; the blur-filter
edit was removed.

## Correctness and loader checks

- All 18 final comparison arms passed; parent binary/config integrity and
  process cleanup checks passed.
- Direct output-framebuffer readback did not request screencopy or cause a full
  redraw. Three small-update phases were pixel-identical to separately forced
  full-redraw references, with 23,084 / 33,524 / 47,444 damaged pixels rather
  than 9,216,000 (99.5–99.75% fewer pixels).
- The public headless pan runner passed normal, overview, and returned-normal at
  scale 1.5; start/returned images were identical. This is a regression check,
  not a navigation performance comparison. The temporary wrapper needed the real
  configuration module path in `LUA_PATH`.
- Builds reused the existing warm Ninja cache, compiling Renderer.cpp only,
  except one removed experimental GLRenderer.cpp edit. No clean/bootstrap build
  or desktop restart occurred.

## Provenance and artifacts

Exact hashes and reduced results are in `results.json`. Tested production binary
SHA256: `7706b87a3054febeffcb38e32f367ca9d417619cbb2b008e92dcc7f32f79c0f0`.

Full artifacts:
`/home/daphen/.cache/hyprland-canvas-dev/partial-damage-implementation/`. Final
comparison: `compare/run-20261001-192921/`; direct readback:
`visual/run-20261001-193022/`; navigation check:
`navigation-final-module-path/`.

The production source and warm build were restored after diagnostic
instrumentation. After explicit approval, the tested package was installed to
`/home/daphen/.cache/hyprland-canvas-dev/validated`. Its binary hash matches the
tested production binary, and the real configuration passes `--verify-config`.
The existing session launcher uses this exact path. The running compositor
retains its original hash and was not restarted.
