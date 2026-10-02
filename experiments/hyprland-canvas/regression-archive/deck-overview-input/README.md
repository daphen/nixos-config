# LT + right-pad native overview entry

**Five native lines staged on top of the separately committed/pushed pool
improvement `5ed47fe`.** The public InputPlumber wheel path now enters the
existing native overview on its first nonzero movement with Super held, then
performs the existing pan. Local regression fails the old binary and passes the
candidate. No Deck activation was performed.

## Trace and change

At repository `5ed47fe881e59f9fdb95b671f277419d1c8f469d`, native diff
`4970d945f3e19ff9bed00c22f901fa36ccccd67f67739cefe3de628e233821ad`:

1. The Deck profile maps LT to `KeyLeftMeta` alongside its gamepad trigger.
   `inputplumber-native-gestures.patch::translate_desktop_pads` routes
   `RightPad(Motion)` to `Mouse(Wheel)` only while `KeyLeftMeta` is active;
   otherwise it preserves pointer motion. Zero translated deltas are already
   discarded by the sender.
1. Physical mouse input reaches `CInputManager::onMouseWheel`. Its existing
   Super branch called only `canvasPan`, which updates camera/panning state but
   does **not** set `m_canvasOverview`, the reveal transition, or an overview
   zoom target.
1. Before that existing pan, the new InputPlumber-only condition calls
   `canvasOverview()` when the effective delta is nonzero, overview is not
   already active, and no window drag is active. The existing session-lock,
   input-capture and shortcut-inhibition guards remain outside this block,
   unchanged.
1. The Deck-only Steam relative-motion branch in `onMouseMoved` gets the same
   first-nonzero-movement entry. Its existing raw-device, Super, lock, capture,
   inhibition and drag conditions are unchanged.
1. Existing `Super_L`/`Super_R` release bindings still call `pan-end`. No LT
   press binding, launcher/radial modifier, protocol, state mirror, QML overlay,
   header or runtime flag was added.

The three wheel lines live in `whole-canvas-camera.patch`; the two Steam motion
lines live in `machines/steamdeck/hyprland-deck.patch`. Applying those patches
in order to an isolated Git index produces InputManager blob
`d07975cfa2f705faa4b13b9ae942575782a86cba`, exactly matching the built native
source.

## Device identity: raw versus IPC names

`CMouse` assigns `m_deviceName` directly from Aquamarine `getName()`. Device
registration separately computes `m_hlName` with `getNameForNewDevice`, which
normalizes the raw string and adds a uniqueness suffix. IPC reports `m_hlName`.

Thus the parent-reported live IPC names `inputplumber-mouse` and
`extest-fake-device-1` are **not raw device names**. In particular, `-1` does
not prove the existing raw `"extest fake device"` guard is wrong. The wheel
guard uses raw `"InputPlumber Mouse"`, also found in the existing packaged
InputPlumber 0.78 binary. The original Steam raw-name guard was deliberately
retained rather than changed to an IPC alias.

A read-only live `/sys/class/input/event*/device/name` confirmation was
requested from the parent. The parent was awaiting an unanswered question, so
that confirmation was not received in this worker turn. The parent owns that
final hardware identity check and any approved Deck activation; this worker made
no SSH connection.

## Public regression and limitations

`canvas_deck_input_test.py` uses the existing isolated GL hierarchy and real
public Wayland pointer/key protocols. Its test-only shared library overrides
**only** the nested Aquamarine pointer's reported device name. Actual axis
events traverse the private parent, nested Wayland backend, native input
manager, camera, renderer and public monitor query. This does not emulate or
claim a physical Deck gesture.

Final valid runs in `results.json`:

- Pool-baseline binary: fails first-controller-delta overview entry, as
  expected.
- Candidate `InputPlumber Mouse`: unmodified input, Super alone and zero delta
  do not enter; first nonzero Super+wheel enters; repeated movement stays in
  overview; public Super release exits; existing overview scrolling remains
  supported; dragging does not enter overview.
- Candidate `Generic Test Mouse`: the same Super+wheel does **not** enter
  overview; normal existing overview scrolling and release behavior remain
  supported.
- Both candidates pass the existing settled rendering/late-client checks, plus a
  real session lock with controller key/axis input leaving the locked output
  byte-identical. The test greeter's ordinary unlock indicator is disabled for
  these cases so keyboard UI feedback is not mistaken for camera movement.

Input-capture and shortcut-inhibition conditions were preserved by source
inspection, not exercised through a portal/grab fixture. The Steam
**relative-motion** branch was inspected but not driven locally: the nested
backend transports pointer position, not the physical Steam relative-motion
event. Real pad behavior and Steam fallback still require the parent's approved
hardware check.

Fixture failures were corrected before the final runs: an old compiled key
helper lacked `--hold`; the private parent's discrete-wheel emulation turned a
zero packet into a detent; and the lock greeter initially displayed its key
indicator. The final fixture compiles the current key helper, disables discrete
emulation only in the private forwarding parent, and uses a no-indicator test
greeter. No candidate feature depends on these test settings or on the name shim
in production.

## Artifacts and build

- Native final diff:
  `fa7bb1ff6a91fa57517b9993d9c5fb52e3e00ee8796d1280eb32caf83d2ba557`.
- Candidate executable:
  `082fdd95eb3689425bdc94255836f8221625edaccf24fe7e300710554b3baa36`.
- Artifact: `/home/daphen/.cache/canvas-deck-overview-input/Hyprland-input`.
- Raw runs and replay:
  `/home/daphen/.cache/canvas-deck-overview-input/{run-input.sh,verify-input.sh,baseline-inputplumber,candidate-inputplumber,candidate-generic}`.

The production build was one warm incremental `InputManager.cpp` compile plus
relinks, two jobs, using the same exclusively granted
`/home/daphen/.cache/hyprland-canvas-secure-lock/{source,build}` and
`dev build --no-publish`. The small name/key fixtures were compiled separately
as test tools; no second Hyprland source or build root was created. No
configure, clean, bootstrap or header invalidation.

The validated binary, original Deck store binary and pushed pool artifact remain
untouched. All owned test processes exited. No Deck SSH/update, desktop restart,
theme, mlqs, or live setting change occurred. Controller changes are staged
separately, not committed/pushed or activated; parent confirmation is required
before deployment.
