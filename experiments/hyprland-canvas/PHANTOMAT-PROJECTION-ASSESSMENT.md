# Canvas projection and motion — read-only assessment

**Primary missing visual: PhantOMat's curved world projection.** Our tested
candidate has rounded window corners and affine zoom, not a lens or lens blur.
Keep the tiling model; evaluate the lens at the existing rendering boundary, not
by adopting upstream's floating desktop. No new implementation or build was
performed for this assessment.

## User-observed result: no demonstrated visual win

David watched the driven laptop demo and reported motion looks the same as live.
Treat that as a **qualitative negative finding**, not approval of the focus-only
candidate. Do not activate or recommend it as the requested visual upgrade.
Tiling remaining the same is intentional. Zoom-out/return still use the old
spring, and projection/blur remain absent; the staged candidate has not
delivered the requested overall feel.

## Exact state inspected

- NixOS HEAD: `13055a25137e023ca4b2a9ede35587e4a86684aa`.
- Native HEAD: `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Complete current native dirty-patch SHA256:
  `b7d26ea48ed811e60692b18573fe346adb0175289ee697666d32c7b8484033bd`.
- Tested candidate binary:
  `f5c4c5bfdab9786f2d2e67d3e4f627f8ade6cf44c8a2104369d9e3a35f846ea8`.
- Upstream checkout is clean at `2e33ec12e9d0a7699c61307c1e04909badb75e75`. It
  was inspected, not built/run.
- Read-only live IPC confirms no screen shader on either compositor. Candidate
  `canvasFocus` is `canvasCameraEase`, speed 8; `canvasCamera` is still
  `spring:canvasMotion`. Live has the spring camera and no focus-only leaf.

Native paths below are relative to
`/home/daphen/.cache/hyprland-canvas-dev/source/`; upstream paths are relative
to `/home/daphen/.cache/phantomat-inspection/`.

## 1. Rounded zoom-out projection

**Already works:** affine camera translation/scale, ordinary window rounding,
world grid, dim tint, selection outline and minimap. Native
`src/render/Renderer.cpp:2444–2476` draws the background, transformed tiled
clients, selected outline, chrome, then untransformed foreground content.
`src/render/ElementRenderer.cpp:316–325` scales window corner rounding.
Increasing that radius would not produce the curved world David is asking for.

**Missing:** radial sampling/overscan, edge feather and the corresponding
pointer mapping. Upstream `shaders/barrel.frag:177–192` maps normalized screen
coordinates with `(1 + strength * radius²) / edgeScale`; `Config.cpp:311–322`
defaults to strength 0.14, edge scale 1.08, feather 0.025.
`scrollOverview.cpp:8744–8767` links lens strength to overview progress.
Optional edge blur uses 24 taps; chromatic fringe can multiply each tap into
three samples (`barrel.frag:158–222`). Our preview has neither this projection
nor this blur.

**Smallest existing production boundaries:** the tiled-world block in
`Renderer.cpp:2444–2476`, plus its existing screen-to-world conversion in
`src/desktop/state/ViewHitTester.cpp:25–29`. The latter currently only undoes
translation/scale. A lens must apply the same screen-to-source mapping first;
upstream does exactly that in `scrollOverview.cpp:656–677`. Preserve unwarped
bar/picker/top-layer interaction and native window keyboard focus.

There is already a postprocessing mechanism: native
`src/render/OpenGL.cpp:830–895` and `src/output/MonitorResources.cpp:46–61`
acquire reusable work framebuffers. Upstream's `BarrelShader.cpp:138–188` uses
the existing final-screen shader. **Correction to a too-broad earlier
assumption:** a new framebuffer architecture is not necessary. The pool may
reuse existing storage. However, installing a whole-screen shader alone is not a
production-complete solution: it also warps our already-composited HUD/layers
without fixing hit testing. Upstream separately composes HUD/minimap after its
lens (`barrel.frag:222`). Our integration must keep the equivalent world/chrome
boundary; no new window-layout model is needed.

**Bounded first evaluation recommendation:** world-only radial lens, animated to
identity on exit, no 24-tap blur or chromatic fringe. Reuse the existing monitor
buffer pool and pair rendering with the existing input conversion. Do not sell a
shader-only, misaligned-click screenshot as a working implementation.

**Cost:** at least one additional full-resolution sampling/composition pass. One
3840×2400 RGBA8 work target is 35.2 MiB; a 3840×2160 target is 31.6 MiB. Those
are storage sizes, not guaranteed incremental allocations; format/HDR and
color-management passes can cost more. A read+write of the laptop-sized image
alone represents about 70.3 MiB of raw traffic per full-frame pass, before cache
and other rendering effects. No measured lens GPU-time result exists yet.
Expected edits touch renderer/backend/input implementation seams and a shader;
prefer roughly 3–4 warm translation units with no shared-header change. If the
existing API requires a broadly included header change, stop and disclose the
larger rebuild rather than silently triggering it. No cold bootstrap is needed
for the current compatible cache, and none is authorized.

## 2. Camera feel and navigation

**Already works:** actual keybind → native canvas dispatcher → Lua tiled
selection → real window focus → camera centering. Native
`src/layout/LayoutManager.cpp:93–136` and `src/output/Monitor.cpp:240–275` keep
those responsibilities separate. The tested focus-only candidate already uses
upstream's example curve `(0.22,1),(0.36,1)` over 800 ms.

**Remaining mismatch:** upstream creates zoom, transition progress and camera
offset from one animation configuration (`scrollOverview.cpp:1497–1535`). Ours
still uses the fast spring for zoom/pan/release and the long Bézier for focus
(`Monitor.cpp:104–115,160–185,279–298`). That difference can make otherwise
similar moves feel disconnected. Both Bézier implementations retarget from the
current value; neither establishes velocity-continuous Bézier retargeting. There
is no evidence requiring a replacement motion engine.

**Smallest overview-motion options, before any implementation:**

- A private config-only comparison can assign a different curve to the existing
  `canvasCamera` leaf: no native rebuild, but it also changes pan/release and is
  therefore an evaluation, not a recommended production setting.
- The contained production seam is an overview-entry/exit animation leaf in
  `AnimationTree.cpp`, selected for zoom and X/Y by the existing
  `Monitor.cpp::canvasOverview/canvasFinish` mode switches. Restore the gesture
  leaf on pan, preserve the existing focus path, and use rendered values when
  switching curves. Estimate 30–50 native lines plus Lua configuration, two warm
  translation units and no central-header change. This is a proposal, not code.

Evaluate **zoom-out/return** with matched captured phases and burst/interruption
input, rather than further tuning only `canvasFocus`. Pair that evaluation with
actual curved projection if the goal is the upstream visual feel; easing alone
cannot supply the missing lens. Longer transitions render more full-output
frames and may increase total GPU work even if per-frame pacing is unchanged.

Previous executed motion evidence remains relevant, not newly re-run here: 744
px travel reached 90% at about 121 ms with the spring versus 328 ms with the
candidate, with sampled peak speed roughly halved. Normal focus movement cost
about 59 GPU ms per transition versus 33–39 in controls: gentler does not mean
faster or cheaper. See `PHANTOMAT-EVALUATION.md` for exact evidence identities.

## 3. Invalidation and rendering performance

`Monitor.cpp:104–108` damages the whole monitor on camera updates.
`Renderer.cpp:3058–3064` also promotes transformed canvas client damage to
monitor damage. Changing the projection changes pixels across the output, so a
full-output redraw while camera/lens parameters animate is expected. Keep a
settled, unchanged view event-driven; do not add a time-uniform redraw loop or
disable damage tracking globally (`OpenGL.cpp:1051–1081` warns about that cost).
A moving overview is already fully damaged: the lens adds sampling/composition
work, not a magic reduction in invalidation.

Existing matched palette-candidate versus preceding visual/focus A/B/A results:
normal median GPU time per submitted nested frame 0.225 / 0.225 / 0.219 ms;
overview 0.387 / 0.401 / 0.381 ms. This measures the current non-lens builds,
not physical FPS and not a forecast for the lens. Reusing a fixed buffer does
not remove the full-screen bandwidth bill.

Static risk, not a reproduced regression: grid/text caches in
`Renderer.cpp:152–153,224` have single entries shared across outputs. Different
scales can churn them; reproduce simultaneous output redraws before proposing a
cache rewrite. The prior 1440×900 test cannot establish physical dual-4K cost.

## Tiling preservation and required acceptance

The Lua model is the spec; do not replace it. Verified live source:
`hyprland.lua:850` binds Super+Shift+H/J/K/L to `move`; `378–416` moves the
selected tile between rows while preserving alignment; `908–909` bind
Alt+Shift+J/K to `move-row`; `468–478` swap row membership. Native
`LayoutManager.cpp:131–133` forwards these unhandled messages to the Lua layout.

Before approving a projection/motion candidate, add isolated public-input tests
using the standard-keymap injector for **both move J and K, and move-row J and
K**. Check expected membership/order, inverse moves restoring geometry,
selected-window identity and actual app key delivery after every move, in normal
and overview modes and across entry/exit. Also verify pointer targets/popups at
curved edges, fractional scale, and flat UI layers. Existing fixtures only
executed move J; this document does not claim the missing directions have
passed.

## Scope and preview ownership

The driven palette run is complete; keep its eight functional controls/backend.
Its eventual UI must use the existing **bar-spawned Quickshell picker style**,
not this standalone popup. No further palette polish is proposed. The existing
preview remains on eDP-1. The coordinating session took over the short visible
motion demo; this session has not run `motion-demo.py` or sent further preview
input after that handoff. Do not tear down the preview without David explicitly
asking to stop that preview. Native implementation, broad build invalidation and
live activation require separate approval.
