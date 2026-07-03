# site-tweaks

Per-site page-world shims for Helium. Deliberately standalone — NOT part
of chromium-palette (unrelated concern).

## Install (one-time, personal profile only)

`helium://extensions` → Developer mode → Load unpacked →
`~/nixos/dotfiles/chromium/site-tweaks`

The work profile doesn't need it.

## Shims

- **netflix-main.js** (`netflix.com`, MAIN world, document_start)
  - Hides AV1 from MSE/mediaCapabilities: the Widevine-L3
    `av1-hd-bitrate-capped` ladder software-decodes with dropped frames,
    so Netflix downshifts to 540p/250kbps regardless of bandwidth.
    Without av01 it serves the healthier VP9/H.264 ladders. EME/DRM
    untouched.
  - Pins `document.visibilityState` to visible so quality survives
    unfocused/hidden playback (pairs with the browser-config.sh
    anti-throttling flags).

Verify with Netflix's stats overlay: Ctrl+Alt+Shift+D — expect vp09/avc1
codec, bitrate in the thousands, ~0 dropped frames.
