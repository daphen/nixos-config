# Sprite project

This folder is a spritecook project: pixel-art game sprites drafted by AI and
finished by hand in Aseprite. `spritecook.json` fixes the sprite size and
`palette.gpl` the palette; every sprite must stay within both.

The user watches the Cockpit sprite bench on the left. It reloads by itself from
`preview/` whenever a command finishes or Aseprite saves, so never open images
or paste paths to show results; describe what changed instead.

## Commands (run from this folder)

- `spritecook draw <name> "<description>"` — new sprite `<name>.aseprite` from a
  description. Describe the character, outfit, props and view; style, outline
  and background are added automatically. About 30 seconds.
- `spritecook animate <name>.aseprite <tag> --frames N --prompt "<motion>"` —
  appends an animation (idle, walk, run, jump, attack, hurt) generated from
  frame 1. Use 4 frames for walk/idle, 6 for run/attack.
- `spritecook lint <name>.aseprite` — counts stray pixels, doubled outline
  corners, off-palette and semi-transparent pixels; the bench marks them.
- `spritecook export <name>.aseprite` — sprite sheet + JSON in `export/`.
- `--from raw/<file>.png` reruns cleanup on an earlier raw image for free;
  `--tolerance` (default 60) controls background removal.

Every generation costs money. Rerun cleanup with `--from` before generating
again, and confirm with the user before more than two generations in a turn.

## How pixel art is finished

1. Silhouette first: the shape must read at 1x. Judge it before details.
1. Outline: one pixel wide, no doubled corners, no gaps.
1. Colour: flat clusters from the palette; no lone noise pixels.
1. Shading: one consistent light direction (top left), ramps not gradients.
1. Animation: key poses first, then in-betweens; feet and head bob 1px.

Hand-editing pixels is the user's job in Aseprite (`aseprite <name>.aseprite`,
menu Edit → Spritecook). Suggest what to fix and where, by frame and x,y.
