# Tune the Look — isolated palette result

**Complete and staged, not activated.** Eight real controls, compositor
readback, atomic persistence, keyboard isolation and focus restoration pass at
1× and 1.25×. The live Lua, running compositor and validated package are
unchanged. Lens and wallpaper parallax remain separate, unimplemented work.

## Delivered behavior

`tuning/init.lua` loads the existing focus curve, then the managed overrides,
starts the separate staged Quickshell entry point and binds **Ctrl+,**. It is
not sourced by the live config. No development flag is required by the palette.

- Type to filter; ↑/↓ select; ←/→ apply; Shift fine-adjusts; Home resets the
  selected control; Esc releases the layer-shell keyboard grab.
- The dark translucent, rounded panel uses uppercase mono labels, numeric units,
  tracks, orange selection, a glowing search border and explicit save status.
  Accent presets change the real overview outline, minimap and palette together.
- The eight controls are focus duration, grid opacity/spacing, backdrop dim,
  accent, selection gap, minimap width and HUD/minimap panel opacity. The last
  control does not change the tuning palette's own opacity.
- Opening reads the focused monitor and actual compositor settings. Each edit
  reads fresh values under a local file lock, applies the existing Lua config
  API, reads back acceptance and atomically replaces
  `$XDG_CONFIG_HOME/hypr/canvas-tuning.lua` (fallback `~/.config/hypr/`). The
  lock serializes helper edits; it is not a stale-read/version protocol.
- Saving failure reports **APPLIED, NOT SAVED**, retaining the accepted live
  value. Nothing rewrites the main Lua. There is no authoritative client-side
  settings copy, pending-value queue, new socket protocol or settings daemon.

The standalone staged Quickshell host keeps the live desktop shell untouched;
`tune.py` is a short-lived helper. The palette does not enter/exit overview or
remember window focus. Open overview first to preview grid/chrome behind it; it
also works in normal view. The compositor restores keyboard focus on unmap.

Implementation size: **210 QML + 102 Python + 12 Lua lines**, plus six bounded
native options and renderer substitutions in two translation units. No native
headers changed. The build reused the existing warm Ninja cache with
`./dev build --no-publish`; no bootstrap, export, publish or restart of a live
service occurred.

## Recorded identities

- Model verified: `openai/gpt-6-astra`.
- NixOS HEAD: `13055a25137e023ca4b2a9ede35587e4a86684aa`.
- Native HEAD: `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Pre-palette complete native dirty-patch SHA256:
  `7001ef84222173309721cf29c170f85022ec36207f331bbe838116126538db9f`.
- Tested complete native dirty-patch SHA256:
  `b7d26ea48ed811e60692b18573fe346adb0175289ee697666d32c7b8484033bd`.
- Tested candidate binary SHA256:
  `f5c4c5bfdab9786f2d2e67d3e4f627f8ade6cf44c8a2104369d9e3a35f846ea8`.
- Unchanged running/validated binary SHA256:
  `ebc11853e57070ce6b919f62e9081e588fb2b418abeda7c8df260c65d5b664b5`.
- Unchanged live Lua SHA256:
  `82c286c4735bbf2c95aaa02951c46a7dd26c084072f4ad9a5ebec747f7ac09bd`.
- `phantomat-tuning.patch` SHA256:
  `b6f11e73a83e07b4a70cd0f831ff2157b66e8455428b475e3f12336ce025dc48`. Apply
  after the previous visual/focus patches, not to bare native HEAD.
  Reverse-apply validation against the candidate passes.

Evidence root: `/home/daphen/.cache/hyprland-canvas-dev/phantomat-tuning/`.
`delivery-hashes.json` records the delivered runtime/test file hashes; both
functional runs' exact input hashes were rechecked against current files. The
candidate binary is `Hyprland.tuning`; `build.log` records the warm build.

## Executed acceptance

`verified-1x/result.json` and `verified-125x/result.json` both pass:

1. Real compositor Lua and Qt/Quickshell loaders, without QML errors. Ctrl+,
   opens a genuine exclusive overlay. Filtering, no matches, arrows, fine steps,
   reset and min/max clamping exercise real key delivery.
1. All eight real values change and are read back. Typed filter text and
   adjustment keys do not reach any app. Save-failure injection leaves the live
   accepted value visible with an explicit error.
1. Esc, three repeated open/close cycles and terminating the palette process
   restore `x` delivery to the **same original Editor window**. Tiled geometry
   and row membership are unchanged in both normal and overview paths.
1. Saved settings survive terminating and starting the isolated compositor
   again, using the same private config directory. All eight reloaded values
   match the accepted snapshot; configerrors remains empty.
1. While closed, no `canvas-tuning` layer remains. In each two-second post-close
   sample, both compositor and palette record **0 GPU ms and 0 CPU ticks**.
   Before first opening, the palette has no readable DRM client, recorded as
   unavailable rather than a fabricated zero.

Images retained: `candidate/palette-overview.png`, `palette-adjusted.png`,
`world-adjusted.png`, `save-failure.png` and `no-matches.png` under each run.
Both overview captures and the 1× save-failure image were visually inspected.
The 1.25× capture verifies the scaled layout without clipping the controls. This
remains a single-output acceptance result, not a multi-output validation.

## Cost, not FPS

In the two-second settled-open sample (including the search caret blinking):

| Scale | Compositor GPU time | Palette GPU time |
| ----- | ------------------: | ---------------: |
| 1×    |             2.62 ms |          1.50 ms |
| 1.25× |             3.01 ms |          2.37 ms |

`closed-aba-1x/result.json` compares the previous visual/focus binary against
the palette candidate, with the palette never opened and identical focus curves.
Three two-second pan trials per mode, A/B/A, pass geometry, key delivery,
normal-view pixel equality and matched transition captures.

| Median per submitted nested frame | Previous | Candidate | Previous repeat |
| --------------------------------- | -------: | --------: | --------------: |
| Normal GPU ms                     |    0.225 |     0.225 |           0.219 |
| Overview GPU ms                   |    0.387 |     0.401 |           0.381 |
| Normal submission-gap p95, ms     |     8.79 |      8.94 |            8.71 |
| Overview submission-gap p95, ms   |     8.90 |      8.77 |            8.88 |

Overview cost was about 4% above the first control; the repeat also varied,
including one lower-frame-count trial. This is **not evidence of a speedup**,
nor a physical-display FPS measurement. Normal/returned PNGs are byte-identical
across all three runs. The settled A/B RGB difference is only 13 channels of
3,888,000, each by one level; A/A itself differs by 3,053 one-level channels. No
camera-trajectory change was made in this slice.

## Reproduction

Use the recorded candidate and the existing isolated harness, never a live
config include without separate activation approval:

```sh
BASE="$HOME/.cache/hyprland-canvas-dev"
python3 experiments/hyprland-canvas/test-canvas-visuals.py \
  --baseline "$BASE/phantomat-visuals/Hyprland.baseline" \
  --candidate "$BASE/phantomat-tuning/Hyprland.tuning" \
  --parent-instance /run/user/1000/hypr/EXACT-LIVE-INSTANCE \
  --output "$BASE/phantomat-tuning/new-acceptance" \
  --ffmpeg /path/to/ffmpeg \
  --candidate-config experiments/hyprland-canvas/tuning/init.lua \
  --candidate-only --tuning-tests --scale 1.25 \
  --key-sender "$BASE/phantomat-tuning/keys"
```

The injector is built from `canvas-key-sequence.c` with the existing generated
virtual-keyboard protocol files, `wayland-client` and `xkbcommon`. Tests run
serially and temporarily hide their nested bootstrap window using the same
short-lived parent window rule as the previous visual harness; cleanup passes.
The shipping patch, live shell/config and validated binary remain untouched.
