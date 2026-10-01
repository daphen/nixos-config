# Reference port: exact boundaries and current interaction slice

Target: the reference's visible canvas treatment and choreography, retaining our
Lua tiling and input methods. This supersedes the older projection-only
recommendation. No live activation is approved.

## Current POC

`preview-minimap-latest` PID29826 runs combined `9e2d65…94108a`: minimap
removed, HUD/selection retained, two normal-focus render predicates changed.
Exact-binary `--minimap-smoke` passed loader/input/focus/overview return and
geometry; approved visible replacement has empty configerrors and36/36 gaps.
Old0124/config remain for rollback. This is not a performance claim: old0124
recovered spontaneously. Live is unchanged. Reversible live trial needs explicit
TTY/session approval; reference parity is a final ship gate, not a prerequisite
to trying the POC. Selected executable:
`phantomat-lens/direct-port/minimap-v1/Hyprland` under the persistent dev root.
`build/Hyprland` is an unselected minimap-only build; do not publish that as the
selected artifact. Source patchc9a75ef8…df87b matches9e2d65.

## Recorded sources

- NixOS `13055a25137e023ca4b2a9ede35587e4a86684aa` plus existing dirty work.
- Native `/home/daphen/.cache/hyprland-canvas-dev/source`, HEAD
  `12f3780fae50a2edf8c50587bd052e95b8bfe652` plus staged canvas changes.
- Reference `/home/daphen/.cache/phantomat-inspection`, clean HEAD
  `2e33ec12e9d0a7699c61307c1e04909badb75e75`.
- Reference source is inspected, not an executed reference build. Its video's
  effective configuration and presentation trace have not been measured.

## Direct source mapping

| Visible result               | Reference path                                                                                                                                                                                     | Current gap / smallest native adaptation                                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wallpaper blur and parallax  | `scrollOverview.cpp:2479–2672`: capture sharp and blurred background, repeated native framebuffer blur while dirty, crossfade by overview progress, mirror alternating tiles; blend at `9048–9071` | Native `Renderer.cpp:1519–1533` instead runs a separate full-screen lens with periodic texture wrapping. Adapt cached wallpaper and mirrored tiling at the existing backdrop stage; do not blur every window to approximate wallpaper blur. Native `createFB`, `blurFramebuffer`, temporary FB binding and texture pass APIs already exist.                                               |
| Lens and dark corners        | `BarrelShader.cpp:138–191`, `shaders/barrel.frag:177–228`: final composed-world lens, then HUD composition                                                                                         | Native `Renderer.cpp:1519–1533` and `2626–2657` lens background and foreground separately. Compose backdrop/world once, lens once, retain native flat foreground/HUD boundary. Copying global shader installation verbatim would also affect native foreground and configured screen-shader ownership; the world-pass boundary is the local adaptation, not an incompatible graphics API. |
| Zoom-out/return choreography | `scrollOverview.cpp:1497–1559` creates independent animated scale, viewOffset and transitionProgress; `8744–8767` separates effects progress from camera scale                                     | Native `CanvasProjection.hpp:22–25` derives progress from smoothstep((1−zoom)/0.25), saturating at 75% zoom regardless fit target. Add the same independent transition animation at the existing native monitor camera owner, consumed by renderer and inverse hit testing. No new motion engine.                                                                                         |
| Focus/framing                | `scrollOverview.cpp:9550–9570` derives focus offset from current window geometry and keeps oversized top-left visible at 100%; navigation may reserve HUD space                                    | Native `Monitor.cpp:180–211,246–264` already computes tiled fit bounds and oversized focus placement. Adapt coordinate convention/HUD clearance, preserve tiled goals and Lua layout selection. Reference session/freeform window geometry is intentionally not imported.                                                                                                                 |
| Client frame delivery        | `scrollOverview.cpp:8221–8310` sends surface/popup frame callbacks to canvas-visible windows each refresh; `8117–8140` schedules idle/realtime preview refresh                                     | Native compositor already owns output scheduling and client surface presentation. Reference plugin runs inside that compositor; nested preview adds an external compositor/Wayland output. Porting plugin timers cannot certify physical cadence. Measure actual visible changes separately from GPU submissions and input geometry.                                                      |

Reference backdrop invalidation includes wallpaper mode, blur strength,
framebuffer dimensions/format and `markBackdropBlurDirty()` (`8030–8031`). A
cache port must retain actual layer/source invalidation, not only its allocation
checks. Reference `blur` defaults false (`Config.cpp:500`); source capability
alone does not establish the video's effective setting.

## Build boundary

Persistent source/build remain `~/.cache/hyprland-canvas-dev/{source,build}`.
Warm command: `./experiments/hyprland-canvas/dev build --no-publish`.

Measured Ninja dependency graph: changing central `Monitor.hpp` invalidates
**188 objects**. Latest recorded object durations sum to roughly **697 seconds
at two jobs**, plus link/variance. David explicitly approved this cost and the
direct port with “Ok, go ahead then”. That build completed with `--no-publish`;
no cold bootstrap or duplicate source/build root was used.
`CanvasProjection.hpp` has two object dependents. The subsequent 72%-framing
iteration rebuilt only `Monitor.cpp` and linked in the same warm cache.

## Direct-port execution

Canonical approved plan:
`~/personal/notes/storage/plans/phantomat-direct-native-port.md`.

1. Direct port `0124d9e…673b11` passed `cache-check-v5` and `functional-v1` (28
   key checks, 68 captures). Cache refresh, mirror, blur and independent effect
   progress were exercised with real loaders and public input.
1. David approved replacing only interaction preview PID3958370 and its five
   fixtures, then separately approved replacing direct-port PID4064575 and its
   five fixtures. Centered POC PID4110703 now occupies laptop workspace9. Live
   compositor, DP-5 and old palette remained unchanged. No further replacement
   or live activation is approved.
1. David found performance acceptable **in this nested view**, but initially
   rejected motion. Reference examples use `(0.22,1,0.36,1)`, not the sharp
   fallback `default` curve. He accepted the isolated reference-curve tuning at
   speed8 (800ms). The reference video's actual runtime remains unmeasured.
1. David chose 72% zoom around the current view instead of fit-all. Candidate
   `5d07be50…d1c0fb16` changes only `Monitor.cpp` overview targeting, retaining
   the empty-workspace guard and current logical camera goal. Targeted
   `framing-v1/smoke-v3/result.json` passed: centered rendered zoom, normal pan,
   focus/return delivery, tile geometry, oversized title and real lens loader.

Fresh configuration from `direct-port/framing-v1/` is loaded in
`~/.cache/hyprland-canvas-dev/phantomat-lens/preview-centered-72/`: reference
curve speed8, desktop GAP48/Deck4, wallpaper blur1, edge blur0.9, vignette0.9,
curvature0.10, parallax strength0.06/depth0.12. Real readback matches and fresh
state produced client-box gaps52/52. Exact source/binary/config hashes are in
`framing-v1/manifest.json`; the preview manifest records protected-state checks.

David reports clicking between windows is very smooth but another phase feels
slower after the swap. Old compositor and all five fixtures are confirmed dead;
new context has four fixtures, same resolution and byte-identical effect/motion
config as the previous POC. Cause is not established. Visible changes and the
requested native minimap removal are paused until he identifies the phase.
Preserve the accepted focus path; no broad benchmark or new context.

Iteration policy: config hot-reload with readback; native leaf warm build plus
short isolated smoke and separately approved child replacement. No broad
performance/release suite until a candidate is worth shipping. Native changes
are not true hot reload. Physical-input and presentation acceptance remain open.

## Prioritized interaction slice

David explicitly chose normal-size camera pan with nearest-tile settling; only
Super+Tab explicitly zooms out.

- Desktop: production Lua gesture calls `pan-begin` first. Its separate 350ms
  `pan-overview` timer causes delayed zoom. Remove that timer only in the staged
  config copy.
- Deck: LT emits LeftMeta (`machines/steamdeck/default.nix:95–96`); the extest
  relative-motion branch (`hyprland-deck.patch:12–19`) directly calls
  `canvasPan(delta)` while Meta is held. Remove the native auto-overview call in
  `Monitor.cpp::canvasPan`; retain input device/chord guards and release/focus
  behavior.
- Normal Super+h/j/k/l remains the existing binding → layout dispatcher →
  canvasDirection → Lua layout focus path.
- Do not change PAN_GAIN=8 or the critically damped pan spring without measured
  overshoot evidence. An input-gain complaint and spring overshoot are not
  interchangeable.
- Live-linked `dotfiles/hyprland/.config/hypr/hyprland.lua` stays untouched.
  Staged config:
  `~/.cache/hyprland-canvas-dev/phantomat-lens/interaction-base.lua`.

The interaction preview is not the full reference-look port and is not
visual/performance acceptance. Tests distinguish registered gesture callback
replay, virtual input, equivalent Deck receiver input, actual hardware, and
actual on-screen cadence.
