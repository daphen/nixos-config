# PhantOMat-inspired canvas — staged evaluation

**Result:** a verified single-output visual slice and gentler, focus-only camera
motion are staged. Tiling and real keyboard focus pass. This costs more GPU
time; it is not an FPS improvement. Nothing is activated. The usable
eight-control tuning palette has now been implemented and verified separately:
[palette result, persistence and performance evidence](PHANTOMAT-TUNING.md). The
identities and measurements below describe the preceding visual/focus slice.

## Identity and exact inputs

- Session environment verified: `PI_PROVIDER=openai`, `PI_MODEL=gpt-6-astra`.
- Inspected upstream: `kaolti/phantomat` at
  `2e33ec12e9d0a7699c61307c1e04909badb75e75`, cached at
  `/home/daphen/.cache/phantomat-inspection`.
- NixOS checkout: `13055a25137e023ca4b2a9ede35587e4a86684aa`, with pre-existing
  unrelated dirty work preserved.
- Native source: `/home/daphen/.cache/hyprland-canvas-dev/source`, HEAD
  `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Complete baseline native dirty-patch SHA256:
  `6aa28cd16b681a9a84eb22d80d9c1de8b3d936133992e47b16eea35fb70eefa3`.
- Complete final native dirty-patch SHA256:
  `7001ef84222173309721cf29c170f85022ec36207f331bbe838116126538db9f`.
- Baseline binary SHA256:
  `ebc11853e57070ce6b919f62e9081e588fb2b418abeda7c8df260c65d5b664b5`. It is
  byte-identical to the running desktop and `validated/bin/Hyprland`.
- Final candidate binary SHA256:
  `0bfe1054f0efde6eb96b45d75993502002977d69ae25a021e7382d410641c7fd`
  (`phantomat-visuals/Hyprland.focus` below).
- Live Lua configuration SHA256:
  `82c286c4735bbf2c95aaa02951c46a7dd26c084072f4ad9a5ebec747f7ac09bd`; unchanged.

All evidence directories below are under
`/home/daphen/.cache/hyprland-canvas-dev/phantomat-visuals/`.

## Delivered files

| File here                 | Purpose                                                             | SHA256                                                             |
| ------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `phantomat-visuals.patch` | Renderer + orange default; 151 additions / 5 deletions              | `16f491b34d1189e8caa275b820bc0ffc398ce89b90c46aa36a50915e122d07d7` |
| `phantomat-focus.patch`   | Focus animation leaf and curve switching; 20 additions              | `8ae9a966f2c6077b4b3cff175ad1b069a42728ca3d8f98a50c098e0c694e1e80` |
| `phantomat-camera.lua`    | Two-line production configuration for `canvasFocus`                 | `5e3e2637b9fe74ed7be6a9b4e282d3c7117d5a0061fe0679ab840ca3e292c044` |
| `test-canvas-visuals.py`  | Isolated real-compositor A/B/A, captures, input and geometry checks | `6f8e02627224ea9f331167ab7b410a7de7c50c1a3b20296c23ce191619e0c44c` |
| `canvas-key-sequence.c`   | Real virtual-keyboard Super+L/J/H/K with a standard XKB map         | `6afce13b94930e8c0ca55ef8a1e168280f76338b0b7cfde9c9cf638ecab4c538` |
| `measure-canvas-focus.py` | Camera trajectory measured from recorded pixels                     | `e035f477dafb67deae1536103381a5369499b1d1f384b4005c6a23b751a29bb9` |

Both patches apply on top of the recorded dirty baseline, not bare native HEAD.
Reverse-apply checks against the current candidate source pass. The shipping
`whole-canvas-camera.patch`, live Lua, and validated binary were not updated.
The warm native source/build directory currently contains the staged candidate;
do not publish it incidentally with an unrelated experiment.

## What actually changed

1. **World grid and subdued backdrop:** `Renderer.cpp:102–178`. One repeated,
   cached dot texture, anchored to the same world-to-screen camera transform as
   the tiles. A dim tint is behind windows, not over application contents. Dot
   density fades near the smallest zoom.
1. **Coordinated reveal:** backdrop, grid, HUD and minimap derive opacity from
   the existing zoom value. No extra timer, animation manager, protocol, or
   mirrored camera state.
1. **Accent selection and chrome:** detached orange selection treatment, title
   HUD, and non-interactive minimap with selected tile and viewport. Native
   tiled geometry and hit testing are unchanged.
   `Renderer.cpp:180–234,2442–2472`; `ConfigValues.cpp:820`.
1. **Focus-only glide:** `Monitor.cpp:162–175,260–278` and
   `AnimationTree.cpp:30`. A `canvasFocus` animation leaf inherits the existing
   camera behavior unless configured. The two-line fragment supplies the
   upstream example's Bézier. Actual panning, overview entry and release return
   to `canvasCamera`. Switching curve families restarts from the rendered value
   instead of reusing a spring's stale velocity.

No floating-desktop transplant, window snapshots, shader lens, wallpaper
parallax, tuning palette, or new live service was introduced.

## Why navigation looked different

Upstream evidence at the recorded SHA:

- `examples/spatialoverview.lua:49–55,187–190`: speed **8.0**, Bézier
  **(0.22,1), (0.36,1)**.
- `scrollOverview.cpp:1497–1535`: camera offset, scale and transition progress
  use that configuration.
- `scrollOverview.cpp:4511–4547,9549–9576`: selection assigns a new
  camera-offset goal; the camera centers the selected window, with a HUD
  clearance adjustment in navigator mode. Its floating-world placement rules are
  not our tiled-row layout.
- `scrollOverview.cpp:4496–4509`: actual seat keyboard focus is explicitly
  maintained. Visual selection alone is not sufficient.

Our live path is Super+H/J/K/L → `hl.dsp.layout("focus …")` →
`LayoutManager.cpp:129–130` → `CMonitor::canvasDirection` → Lua's tiled
directional selection → actual window focus → `canvasCenter`. The old
configuration is `hyprland.lua:837–840`: mass 1, stiffness 1200, damping 69.282,
approximately critically damped.

The installed hyprutils source is
`/nix/store/44z40x0b9yw31ls77qgkgkwjx6iszw06-y8jz2si4hvxbqlxw978anp4dcls5xq6y-source`:

- `src/animation/AnimatedVariable.cpp:74–79,101–139`: Bézier speed 8 means 800
  ms; **spring stepping ignores that duration setting**.
- `include/hyprutils/animation/AnimatedVariable.hpp:225–247`: spring retargeting
  preserves/rescales scalar velocity. Bézier retargeting restarts from the
  current value; it is not velocity-continuous.

Therefore “we already have magnet behavior” was not visual parity. The tested
change deliberately lowers travel speed and lengthens deceleration. It does not
improve frame rate, and it does not make arrival quicker. Existing gesture
attraction/release-centering is preserved rather than substituted for this
focus-motion comparison.

## Executed focus comparison

Evidence: `focus-isolated-final-2/result.json`, `trajectory.json`, and each
variant's `normal*.mkv/png`, `overview*.mkv/png`.

Same final binary/renderer for A/B/A; only the candidate receives
`phantomat-camera.lua`. Same four tiled GTK fixtures, GPU-backed 1440×900@120
nested output, AC connected, platform profile `quiet`. Each mode has a recorded
sequence plus three unrecorded cost sequences; the interrupted mode has one of
each. There are 54 sequences / 216 navigation keys across A/B/A.

- Slow sequence: Super+L/J/H/K, 1 second between keys.
- Burst sequence: the same keys, 80 ms between keys.
- Both run at normal scale and in overview.
- Additional sequence interrupts an in-flight focus transition with pan-begin →
  pan → pan-end.
- Every sequence reaches Notes → Browser → Terminal → Editor in order. Real
  application `x` keystrokes are received after sequences. Tiled geometry
  remains unchanged. Loader reports no config errors.

The standard-keymap injector is necessary: `wtype` assigns synthetic keycodes,
while our normal binds resolve physical keycodes. An initial `wtype` navigation
attempt was invalid and is not included as evidence. `wtype` remains appropriate
for the separate app-text delivery assertions. No input-resolution override was
added.

### Motion shape and latency

Measured from the amber title-bar stripe in the lossless recording of the first
744 px horizontal transition. Video PTS aligns with screencopy timestamps within
3 ms; motion samples are still limited by recording cadence.

| Metric                | Current spring A / A-repeat | Focus-only candidate |
| --------------------- | --------------------------: | -------------------: |
| 50% travel            |                  54 / 53 ms |               112 ms |
| 90% travel            |                121 / 120 ms |               328 ms |
| 99% travel            |                204 / 220 ms |               528 ms |
| Peak sampled speed    |          9,229 / 9,565 px/s |           4,372 px/s |
| First recorded motion |                  13 / 20 ms |                12 ms |

The candidate roughly halves peak speed and spreads travel over more frames.
Inspected matched entry/mid/travel/tail captures show gentler traversal and
deceleration; burst and interruption captures do not show a geometry jump. This
supports the shape change, not an objective claim that everyone will prefer it.
Focus observation is approximately 6–16 ms across runs, at a 10 ms polling
cadence—not input-to-photon latency. The app is focused before the camera
arrives.

### Focus cost (unrecorded trial medians)

| Mode                       | Spring GPU ms A / A-repeat | Candidate GPU ms | Active submission-gap p95, A / candidate / A-repeat |
| -------------------------- | -------------------------: | ---------------: | --------------------------------------------------: |
| Normal, four spaced keys   |                  154 / 132 |              237 |                               8.56 / 8.52 / 8.59 ms |
| Normal, burst              |                    57 / 46 |               53 |                               8.59 / 8.70 / 8.82 ms |
| Overview, four spaced keys |                  169 / 152 |              165 |                               8.50 / 8.63 / 8.55 ms |
| Overview, burst            |                    73 / 49 |               54 |                               8.84 / 9.09 / 8.95 ms |

The longer normal-scale movement incurs **more GPU work**: about 59 ms per
transition versus 33–39 ms in the controls, including the rest of the
compositor's focus effects. Frame submissions are similar; there is no
demonstrated pacing improvement. CPU totals are noisy and include the same IPC
focus polling in every variant; do not advertise a CPU win.

## Executed integrated visual comparison

Final candidate binary plus focus configuration versus the original
live-identical baseline, A/B/A, five matched 2-second 60 Hz pan traces per mode.
Evidence: `integrated-1x/` and `integrated-1.25x/`.

Both pass geometry, focus, real key delivery, config-loader and
unchanged-live-binary checks. Normal and returned screenshots are byte-identical
within each run. Entry at +25 ms, mid at +75 ms, settled and exit captures were
inspected. Frame extraction uses recording timestamps rather than the latency of
launching `grim`.

| Overview pan | Baseline GPU ms A / A-repeat | Candidate GPU ms | Submission-gap p95 A / candidate / A-repeat |
| ------------ | ---------------------------: | ---------------: | ------------------------------------------: |
| 1×           |                      91 / 75 |              106 |                       8.65 / 8.62 / 8.68 ms |
| 1.25×        |                      64 / 66 |               96 |                       8.61 / 8.63 / 8.59 ms |

These are approximately 275 submissions over 2.29 s including the settling tail,
**not physical display FPS**. GPU busy counters measure the child compositor,
not the recorder or total desktop. The current native submission rate is already
high; the visuals consume additional work without a measured pacing win.

### Validity and limits

- Valid matched workload comparison on the same GPU, geometry, power profile,
  output size and trace; A/B/A exposes baseline drift.
- No GPU/CPU clock lock. Existing desktop load continues. Exact percentage cost
  estimates are not robust against that drift; absolute medians and both
  controls are retained.
- Recordings are separated from cost trials. Recording cadence is not compositor
  presentation cadence.
- Native final source hash and candidate config hash match the tested
  binary/artifacts. Builds were warm incremental with `./dev status` then
  `./dev build --no-publish`; renderer/config units first,
  monitor/animation-tree units later. No central header invalidation or cold
  bootstrap.
- The physical desktop has two 4K outputs at 1.6667× / 1.5×. Tests use one
  isolated 1440×900 output at 1× / 1.25×. Simultaneous multi-output chrome,
  rotation, HDR and physical scan-out pacing are not validated. The current
  single-entry grid/text caches can churn between differing output scales if
  both overviews repaint; this is a concrete pre-activation performance risk,
  not a claim of tested dual-output stability.
- Upstream was **not built or run**. This is our current canvas versus an
  adapted upstream curve/visual slice, not an upstream-plugin-versus-native
  benchmark. A cold upstream build requires separate approval.

## Usable “Tune the Look” palette — next bounded implementation

The requested image `/home/daphen/.cache/heidr-pastes/img769.png` was inspected.
It is the global live tuner, not a per-window menu. Upstream
`README.md:123–137`, `Tuning.cpp`, and `scrollOverview.cpp:10057` implement
Ctrl+, entry, filtering, arrow adjustment and saving.

**Recommendation:** implement this before the lens. It is a separate interaction
feature, not another renderer tweak. Keep it out of the now-recorded motion
experiment.

### Appearance and operation

1. Ctrl+, opens one focused-output, full-screen overlay surface with a centered
   dark translucent rounded panel. Behind it, the selected window, orange
   outline and world grid remain visible. The panel itself is not transformed
   with the canvas.
1. Glowing orange search outline; uppercase monospace category/label/value/unit
   columns; orange slider fill and ticks; selected row orange with dark text;
   compact footer hints. Use the image's visual hierarchy rather than the
   existing generic picker's compact layout.
1. Typing filters; Up/Down selects; Left/Right adjusts; Shift+Left/Right
   fine-adjusts; Home restores the selected default; Esc closes. No command text
   is sent to the underlying app while open. No fake, disabled lens controls.
1. The footer explicitly reports whether values are session-only or saved.
   Failed writes retain the actual compositor value and show an error, not an
   optimistic successful slider.

### Exactly eight real controls

| Category / control             | Existing behavior it will control                                                                      |
| ------------------------------ | ------------------------------------------------------------------------------------------------------ |
| MOTION / FOCUS DURATION, ms    | `canvasFocus` Bézier duration; not gesture spring stiffness                                            |
| WORLD / GRID OPACITY, %        | Current dot texture alpha                                                                              |
| WORLD / GRID SPACING, world px | Current 96 px grid interval                                                                            |
| WORLD / BACKDROP DIM, %        | Current behind-window dim tint                                                                         |
| CHROME / ACCENT                | Existing focus color, reused by selection and minimap; color presets/swatch, not a fake numeric slider |
| CHROME / SELECTION GAP, px     | Current detached outline spacing                                                                       |
| CHROME / MINIMAP SIZE, px      | Current minimap width                                                                                  |
| CHROME / PANEL OPACITY, %      | Current HUD/minimap panel fill                                                                         |

Six currently hardcoded renderer values become bounded normal config values with
real renderer callers; accent and focus duration already have real config paths.
Do not invent a generic settings registry or advertise upstream's 49 controls.

### Smallest existing seams and focus contract

- Reuse the **layer-shell hosting pattern**, not the browser command-palette
  daemon: `modules/CmdPalette.qml:207–212` already uses an overlay with
  `ExclusionMode.Ignore` and keyboard exclusivity only while open.
  `modules/HyprlandBackend.qml:32` already uses `hyprctl` IPC. Existing pickers
  use `IpcHandler` toggles.
- A dedicated small `CanvasTuning.qml` can use that pattern without expanding
  the 1,100-line generic `Picker.qml` API. No new daemon, socket protocol, input
  hook, floating client, or tiled window.
- Ctrl+, calls its existing-style IPC toggle. Opening reads actual compositor
  values. Arrow handlers set the existing typed config/animation APIs and read
  back the accepted value. Do not keep an authoritative client-side settings
  mirror.
- Closing unmaps/releases layer-shell keyboard exclusivity; the compositor
  restores app keyboard focus. Do not maintain a second remembered window-focus
  state or change row geometry.
- For persistence, recommend one managed Lua override fragment loaded by the
  existing configuration, written atomically by the local helper. Persist only
  successfully applied known values. This must not silently rewrite the user's
  main live-linked Lua. The session-only first version must say so explicitly if
  persistence is deferred.

**Concrete cost/decision:** approximately 250–350 QML/helper lines, 40–60
native/config lines, a launcher/binding and keyboard/persistence tests; two warm
native translation units, no new central headers. This exceeds the
already-validated renderer-only slice and would invalidate the integrated
screenshots/benchmarks. Decide whether to take that separate palette slice,
including persistence, before implementing it; it is not silently included in
this result. That separate slice was subsequently authorized and completed; see
[PHANTOMAT-TUNING.md](PHANTOMAT-TUNING.md).

Acceptance: run the real QML loader in an isolated shell; test filtering and
every real setting against compositor readback; typed text must not leak to the
app; Esc must restore actual app key delivery; rows and focus survive repeated
open/close and a palette process exit; saved settings survive an isolated
compositor restart; inspect image-matched 1× and fractional-scale screenshots;
verify no palette surfaces or redraw loop remain while closed. No visible shell
restart is authorized.

## Explicitly remaining visual work

- **Lens/distortion:** upstream's final shader (`shaders/barrel.frag:177–215`)
  combines distortion, optional edge blur/chromatic sampling and unwarped
  chrome. Porting it honestly requires a composited-scene target,
  cursor/hit-test inverse mapping, popups/layers handling and full-resolution
  cost tests. One extra 3840×2400 RGBA8 target alone is about 35 MiB;
  formats/ping-pong targets can cost more. Do not distort only window pictures
  while leaving input coordinates wrong.
- **Wallpaper parallax:** upstream `scrollOverview.cpp:2555–2607`
  moves/scales/repeats a cached wallpaper layer. Ours renders live background
  layer surfaces. A separate background transform/clipping change and
  coverage/edge tests are required; the world-anchored grid is not wallpaper
  parallax.
- **Backdrop blur / richer shadows:** deliberately not added to this slice. The
  implemented tint and crisp outline are inexpensive substitutes, not parity
  claims.
- **Search/tuning palette:** subsequently implemented and verified as the
  separate [eight-control palette slice](PHANTOMAT-TUNING.md); still staged, not
  activated.

## Reproduction

From the repository root; replace `INSTANCE` with the exact running parent
instance. These commands create private nested test processes, not a visible
desktop restart. Do not run them against an unapproved parent/context.

```sh
BASE=/home/daphen/.cache/hyprland-canvas-dev/phantomat-visuals
FF=/nix/store/jfnnrn72slgs4ryx4g09lb97r193xddp-ffmpeg-8.1.1-bin/bin/ffmpeg
python3 experiments/hyprland-canvas/test-canvas-visuals.py \
  --baseline "$BASE/Hyprland.baseline" --candidate "$BASE/Hyprland.focus" \
  --parent-instance "$INSTANCE" --output "$BASE/new-focus-run" --ffmpeg "$FF" \
  --candidate-config experiments/hyprland-canvas/phantomat-camera.lua \
  --focus-sequences --key-sender "$BASE/canvas-key-sequence" --repeats 3
python3 experiments/hyprland-canvas/measure-canvas-focus.py "$BASE/new-focus-run" --ffmpeg "$FF"
```

For integrated visual/pan tests, omit `--focus-sequences` and `--key-sender`,
use `--repeats 5`, and run once with `--scale 1` and once with `--scale 1.25`,
each into a fresh named evidence directory. The C injector is a tiny fixture
compiled against installed `wayland-client`/`xkbcommon` and a generated
`virtual-keyboard-unstable-v1` client header; it does not require a compositor
rebuild.
