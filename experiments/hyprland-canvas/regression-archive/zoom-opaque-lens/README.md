# Canvas zoom: opaque-lens prototype rejected

**Do not ship this prototype.** A five-line renderer change preserved the tested
pictures but reduced local GPU work only **1.6%** while measured CPU time
increased **4.3%**. The shipping camera patch is unchanged. This was
implemented, warm-built and measured, not a report-only source audit.

## Change and production path

The existing bindings dispatch `hl.dsp.layout("overview")` or the native pan
commands. The existing Unix IPC dispatcher reaches `LayoutManager.cpp`, then
`CMonitor::canvasOverview`/`canvasFinish` and the native animated camera. Normal
Wayland configure/ack/buffer commits supply window content. `Renderer.cpp`
composes the cached backdrop, chrome, transformed windows, lens, overlays and
lock surface. No transport, handshake, state mirror or camera API was added.

The backdrop already caches its sharp and blurred images:
source/config/geometry/transform changes invalidate it, not each zoom value.
Window captures already have content-serial/size checks. Locked rendering uses
frozen captures, excludes fresh windows and retains the denied/missing-lock
checks. These paths were not changed.

`rejected-lens-opaque.patch` changes only `CCanvasLensElement` in
`Renderer.cpp`: omit its destination clear, output alpha 1 and disable blending
during the full-screen lens draw. It preserves the original blend-function side
effect and restores the original blend enable state. Previously, source-over
opaque black produced the same RGB and alpha 1. The world clear, lens sampling,
vignette, blur, parallax and all lock decisions remain unchanged.

The prototype is an **archive artifact**, not an input to the flake. No new
cache, shader-quality reduction, header change or runtime flag was introduced.

## Controlled comparison

AC-powered Proart, existing **quiet** profile; AMD Radeon 890M / radeonsi / Mesa
26.0.5 / kernel 7.0.0. Four static GTK Wayland windows and a real layer-shell
background. Raw output 800×1280, transform 3, scale 1; the nested backend
actually reports 60 Hz, not Deck panel presentation at 90 Hz.

A private Weston GL process bootstraps a private baseline Hyprland headless
parent. The measured compositor nests in that compatible Hyprland parent. No
production socket, window rule, visible preview or service restart is used. The
pre-existing Weston protocol-advertisement shim is confined to the bootstrap
process; it is neither a production dependency nor a candidate change. The
disconnected bootstrap Wayland output is disabled; the headless parent supplies
frames. Parent overhead is excluded from the child's counters; both arms use the
same parent binaries, configuration and affinity.

Child, Hyprland parent and Weston are pinned to separate physical cores 2, 0 and
1\. Affinity changes affect only these test processes. Both arms use the same
original parent binary, driver, config, capture method and workload. Three
warm-up zoom round trips precede three trials of six round trips each. Four
serial runs use **A/B/A/B**, giving 36 measured round trips per binary.
Screencopies run outside the cost measurements.

| Per submitted nested commit |    Original |   Prototype |  Change |
| --------------------------- | ----------: | ----------: | ------: |
| GPU engine busy time        | 0.634782 ms | 0.624587 ms | −1.606% |
| CPU time                    | 0.259058 ms | 0.270270 ms | +4.328% |
| Total submitted commits     |       5,327 |       5,328 | +0.019% |

GPU run medians: **A3 0.635258, B3 0.624372, A4 0.632658, B4 0.617456 ms**. CPU
run medians: **A3/A4 0.259009, B3/B4 0.270270 ms**. CPU counters have 10 ms
resolution per trial; the small CPU increase is an observed cost, not a claim
about its cause.

Before the final results existed, acceptance required the GPU run-median
improvement to exceed twice the larger same-binary run-median spread, alongside
non-regressing CPU and exact deterministic pictures. Improvement **0.013044 ms**
did not clear the **0.013833 ms** spread threshold. The small GPU reduction plus
higher CPU cost is not a clear net win; retain the original implementation.

These are per-process CPU/GPU costs, **not FPS, presentation latency or a
Deck/battery smoothness result**. Unpinned early CPU runs were excluded because
core placement was uncontrolled on this heterogeneous CPU. Failed Weston-only
startup attempts produced no valid timing evidence and were excluded.

## Public-path regression evidence

All four controlled runs passed. Eight deterministic images are byte-identical
across every run: normal, returned-to-normal, overview, panned overview,
translucent client, nondefault chromatic/edge-blur/feather, locked, and locked
after a new client maps. The actual session-lock protocol acknowledged the lock;
the late client did not change the parent-visible locked image.

Animations remain enabled for all timing. Only the subsequent deterministic
picture checks disable animation equally on both binaries; otherwise the
pre-existing first-capture window-cache resolution introduces small run-to-run
image differences. The animated overview and pan captures also change as
expected. Configured lens values stay strength **.035**, edge **1.11**, vignette
**.85**, backdrop blur **.7**, parallax **.06**, depth **.12**.

The unchanged public gaming-mode command tests passed **15/15**. No real freezer
test was rerun and no live application was frozen.

## Exact artifacts and restoration

`results.json` records full binary, native dirty-patch, runner, config, fixture,
bootstrap and image hashes, all twelve timing rows, and acceptance arithmetic.
Source checkout base: `bb755898fce128a759e7f2f6bb7fc5979a306ae8`. Native local
base `12f3780fae50a2edf8c50587bd052e95b8bfe652` snapshots upstream
`f05d73f35795ded80d7e1264a37e41b461625f9f`.

- Original measured binary:
  `7f722eb8bf41453e35b931179edceb0940b0bb331328a520459f73ab9a763045`.
- Rejected prototype:
  `62e51941c17b216afef76032233a436b33c3a600174ca946d11ada17c1529ef5`; native
  dirty patch
  `a0109536fdc2c407fcc8becf1da5eddbdc55e91a452d406569f6b9e8ff845076`.
- Restored native source dirty patch:
  `9ee99e15979745e5816cdf04a61f48a6d2e61f253c8e9d961d91c65ec39a02f4` (exact
  original source, including the unchanged Deck overlays).
- Shipping camera patch remains
  `93276f3cab0aa7e79e1b365eba9c0a04b91797a2c72fbaf98b02ab00096297d5`; validated
  package remains
  `1d5a7e4da37076cdb38f39f285b5ad4551fec56dcbe51a7171fc56f60780b611`.

Each build reused
`/home/daphen/.cache/hyprland-canvas-secure-lock/{source,build}`, compiled only
`Renderer.cpp` and relinked with `JOBS=2`, `dev build --no-publish`. No
configure/bootstrap, second source/build tree or publication occurred. The
restored rebuild has its own hash and regression result in `results.json`; it is
not claimed to be the original measured executable.

Raw logs, images, preserved candidate binaries and replay commands remain at
`/home/daphen/.cache/canvas-zoom-performance/`. Reproduce with
`../../test-canvas-zoom.py` and the exact arguments in that directory's
`compare-pinned.sh`; the existing bootstrap helper is
`/home/daphen/.cache/hyprland-canvas-dev/lens-shader-gpu/headless-wl6-advertise.so`.

The running Proart compositor remains PID 2805908 in immutable
`/nix/store/l1klnff6s4mlqckqn2h7yz1lqyan9sz9-hyprland-0.56.0+date=2026-09-10_f05d73f/`,
started before this task. **No Deck SSH, wake, benchmark, deployment or
post-suspend change occurred.** No defaults, appearance files, native lock UI,
gaming serialization/freezer/ANR protection or InputPlumber profile handling
changed.
