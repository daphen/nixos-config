# Working Canvas regression archive — 2026-09-17

Source backup of the isolated native test harnesses previously kept only under
`/home/daphen/.cache`. This is an archive, not a portable CI suite: scripts
still contain the original absolute paths and expect the local validated
compositor, GPU/runtime environment, and NixOS checkout. They create a hidden
nested compositor via a temporary rule in the running parent compositor. Do not
run them blindly on another desktop.

The directory names preserve the original cache-root layout. The focus tests
import the resize harness and virtual-pointer helper. Candidate-specific config
paths must be supplied or restored when replaying a test; this archive
deliberately does not ship stale candidate configs as the active configuration.

`sha256.json` records the archived script bytes. `results/` contains selected
synthetic-fixture results, with the binary/config hashes each run used; it does
not contain desktop captures or application logs. The real Satty result predates
the final Lua-only fixes; the final navigation, move-motion, clearance and
floating input results identify their exact configurations individually.

Current user-confirmed working state:

- Native binary SHA-256:
  `a20311bb91741579da608abad6384df2c1b555422f9c0b860ea35ea5b2eec460`
- Canvas Lua SHA-256:
  `5edcd962416bba775246256779289ba2af72bc82328fea3b4613021f8a628671`
- Native patch SHA-256:
  `6847c61cbeeb98586876c6611b588c6b68ef84dd53173ab6fb405a94e8745c61`

The binary was built using the persistent development build directory. It is not
committed. The pinned flake plus patch rebuild it from source; byte identity
with the development binary is not promised for a Nix package build.

The Steam Deck consumes the relative `hyprland-canvas` flake input from this
repository and selects its package/session by default. Today's package wiring
and config loader were checked, but a complete Deck system build has not been
rerun after today's compositor fixes. Installation still requires the real
hardware/partition checks in the root README.
