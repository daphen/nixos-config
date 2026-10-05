# Verified Steam Deck desktop input checkpoint

David physically verified this layout on 2026-10-05: “This is perfect.”

- Keep Steam's native right-trackpad movement and haptics.
- Disable desktop right-stick mouse movement and LT/RT mouse clicks.
- Preserve every other desktop binding, the Gamepad action set, and the existing
  InputPlumber Canvas profile.
- Apply to both the physical Deck controller and InputPlumber's virtual SteamOS
  handheld controller.

These are exact copies of Steam's saved, reloaded desktop configurations, not
startup overrides. Steam continues to own its editable user configuration. The
running layout is already persistent; no system rebuild or restart is needed.

## Snapshot

The files mirror
`~/.local/share/Steam/steamapps/common/Steam Controller Configs/56279842/config/`.
App `413080` is the desktop layout, not an individual game's configuration.

| File                            | SHA-256                                                            |
| ------------------------------- | ------------------------------------------------------------------ |
| `413080/28de-12f0-35ac322.vdf`  | `6d9d0b9b23e46afd13a1b7f19c940740fec81baa6059896a0255cb14a5e4cda0` |
| `413080/controller_neptune.vdf` | `fbcb7e04d2a6922d24ab3357cbd280ac9583d674b18af44e368c5f9fb9d52d65` |

Only the Desktop action set's right-stick and two trigger source groups changed.
Steam reloads unbound triggers as empty trigger groups; their mode label alone
does not indicate an active mouse binding. The right-trackpad mapping remained
identical, with SHA-256
`02e412dc066c07c3802d6afc6cbe5a18e748d7dfd0eb24779e148a095fbb66c0` over sorted
JSON from Steam's controller editor. Haptics remained enabled with left/right
strength 5.

## Recovery boundary

Do not disable Steam, replace its right-trackpad path with synthetic mouse
movement, or restore the stock desktop layout to solve overlapping controls. Do
not overwrite these snapshots with an unverified candidate.

If recovery is necessary, obtain approval, fully exit Steam, back up the current
files, then restore these four VDF files at their mirrored locations. Start
Steam with approval and verify the loaded desktop layout and physical controls
again. Never overwrite a live Steam controller configuration: its in-memory copy
can overwrite that edit.

This checkpoint does not change the desktop/game-mode transition or implement
same-canvas switching.
