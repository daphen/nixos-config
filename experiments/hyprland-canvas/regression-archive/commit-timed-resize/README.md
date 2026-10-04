# Commit-timed resize — 2026-09-22

Candidate implemented and verified in visible nested compositors, then published
and activated in the main Canvas with explicit approval on 2026-09-22.

Activation verified PID `360834`, the exact candidate binary hash below, an
active `eDP-1` output at scale `1.6666666`, and no configuration errors.
Evidence: `activation-result.json` and `activation.log` under the evidence root.
The former validated package is retained there as `activation-rollback/`.

## Exact candidate

- NixOS HEAD: `fcc8ee42308f275444eedbd92b0904271603981b` plus dirty changes.
- Native base: `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Canonical patch SHA256:
  `b9ea18f82f8ad833747e028df516c1c2ba445523f363bb0fceb4f0e696148a79`.
- Candidate binary SHA256:
  `f4e0133886b890427487bd4f594b8bfb7988779bc6af97eebd012dda401e48b9`.
- Binary: `~/.cache/hyprland-canvas-dev/build/Hyprland`.
- Evidence root: `~/.cache/hyprland-canvas-dev/resize-commit-20260922/`.

## What passed

- Warm-cache build, initially a broad incremental rebuild of shared-header
  dependents (about 110 translation units). Follow-up fixes rebuilt one or two
  translation units. Verification required no cold bootstrap, system rebuild or
  desktop restart; the separately approved activation followed verification.
- Final candidate accepted the canonical Lua configuration with production
  workstation environment settings (`final-verify-config.log`).
- `final-resize/result.json`: nine opaque real-GTK cases — grow, shrink and a
  22-request burst, each with 0, 150 and 500 ms redraw delays. All reached the
  final requested size. Closing a client during a wait left the compositor alive
  past the deadline.
- `final-alpha/result.json`: the same nine cases with 50%-transparent GTK
  content. Captured mixed frames retained opacity and color energy.
- Immediate and 150 ms clients produced blended intermediate frames. With a 500
  ms stall, geometry resumed after the 300 ms deadline without a crossfade; the
  newly drawn content appeared later. This fallback intentionally differs from
  the normal transition.
- Pixel bounds permit one pixel of rasterization variation while waiting.
  Screenshot quantization is not treated as a real size change.
- `final-layer/result.json`: translucent windows over a real `swaybg` layer,
  panning through normal, overview and normal-returned views. All three settled
  images matched `layer-baseline/result.json` exactly (zero changed pixels).
- The old binary failed the new crossfade check as expected: its 51 captured
  frames contained only solid blue or red (`baseline-visible/`).
- A 30-second GTK demo preview ran visibly (`gtk-preview.log`) on the prior
  candidate, before the final non-window-layer guard. It is a demonstration, not
  evidence of user acceptance or a final-candidate pixel test.

All final automated results above identify the same candidate binary hash. Each
isolated runner verified that the parent compositor binary stayed unchanged.

## Reproduce

Use a fresh output directory and the current live parent instance:

```bash
./dev build --no-publish
python3 test-resize-pacing.py --binary ~/.cache/hyprland-canvas-dev/build/Hyprland \
  --parent-instance "$PARENT" --output "$OUT/opaque" --visible
RESIZE_ALPHA=1 python3 test-resize-pacing.py \
  --binary ~/.cache/hyprland-canvas-dev/build/Hyprland \
  --parent-instance "$PARENT" --output "$OUT/alpha" --visible
```

The layer comparison used
`test-canvas-rendering.py --visible --pan-only --repeats 1 --wallpaper "$EVIDENCE/background.ppm"`,
with `RESIZE_ALPHA=1`, first on the saved old binary and then the candidate
using `--reference`. Its nested frame counters are not a physical-display
performance benchmark.

## Limits

This is per-window coordination, not Niri's whole-layout transactions. The
effect uses the existing main-window rendering pass; it does not animate popup
content. Dedicated popup and fractional-scale text regression checks remain
unrun for this candidate. Pointer drags, floating/fullscreen and X11 are
excluded by the production eligibility checks, not certified by a new exhaustive
test matrix. No performance or subjective smoothness improvement is claimed from
these checks.

## Sibling coordination follow-up — 2026-09-22

The user reported smoother resizing but out-of-sync siblings, then approved
coordinating them. This follow-up is exported, not yet activated.

- Patch SHA256:
  `552b8e9b689295c4ff815ff190a24b1595bf25d2e68e2807a47c4f36d7eb3e4b`.
- Binary SHA256:
  `adc96bf4faf051a67e3f1aeca76f84e965f5081bba10365a04f2e85109e29a26`.
- Evidence: `~/.cache/hyprland-canvas-dev/sibling-sync/`.
- Four warm-cache translation units rebuilt; canonical config accepted.
- `final-baseline.log`: prior activated binary fails the same spacing check; the
  captured gap ranges from 28 to 49 physical pixels.
- `final-gap/result.json`: nine opaque two-window cases pass; gap variation
  never exceeds one physical pixel at scale 1.
- `verified-fractional/result.json`: nine translucent two-window cases pass at
  scale 1.6666666; gap variation never exceeds two physical pixels. Moving a
  waiting window to another workspace and closing a waiting window both leave
  the surviving sibling able to animate normally.
- `final-single/result.json`: all nine original single-window cases pass.
- Commands: `test-resize-pacing.py --visible --siblings`; fractional run adds
  `--scale 1.6666666` and `RESIZE_ALPHA=1`; single-window run omits
  `--siblings`.
- One initial test misidentified white fixture bars as gaps; it was corrected
  before recording the comparison. The burst timeout assertion was restricted to
  single requests because returning to the original size cancels a wait. The
  workspace-move check explicitly focuses/centers the survivor before measuring
  it. These were harness corrections, not candidate source changes.

Tiled sibling positions and pending resize animations now share the applied-
content/deadline release. Readiness comes from existing backend state; no new
protocol, persisted participant list or client-state mirror was added. This is
not a full Niri layout transaction system. Popup/fractional text appearance and
subjective acceptance of this follow-up are still separate manual checks.
