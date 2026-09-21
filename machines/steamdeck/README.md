# Steam Deck NixOS configuration

This directory is the source of truth for the Deck system. `default.nix` owns the session, patched compositor and InputPlumber packages, controller profiles, and system packages. `apps.nix` and `keyboard.nix` own Deck applications and keyboard integration. The patch files here are the canonical native and Steam UI changes.

The shared desktop source remains in the normal repository paths:

- `dotfiles/hyprland/.config/hypr/hyprland.lua` and `scripts/` own Deck bindings, radial dispatch, session startup, gaming mode, and palette IPC.
- `dotfiles/quickshell/.config/quickshell/modules/DeckRadialPalette.qml` and `PaletteState.qml` own radial UI and IPC state.
- `dotfiles/quickshell/.config/quickshell/palette-x11/` is the X11 palette entry point; its relative links resolve the canonical modules and QsLib trees.

The runtime chain is InputPlumber profile → Hyprland Lua bindings → repository scripts → Quickshell palette/QML. These sources contain no dependency on reconciliation caches, backups, or Steam userdata. Valve's standard desktop layout remains Steam-managed; no per-user Steam controller layout is required by this chain.

## Validation status

At repository HEAD `9f2a611`, the evaluated InputPlumber package is `/nix/store/cdr7f8ngkfkf7w2xvr3hkxr915dg1dqd-inputplumber-0.78.0`. The built canonical Canvas profile has SHA-256 `f6572a7895fecccda0dd35405f25c0c3af24edcb3873ce452ff068498cfe6a7a`, matching the live Deck profile contents.

The complete canonical compositor patch stack reproduces the live validated source with an empty source diff. The validated binary SHA-256 is `c969033ca0c490403eb9bb4eae99135a6973752ca10c4dfaa063c5f0f6d6f2f8`, and the real config loader accepts the canonical Lua. The radial QML and supporting sources retain the hashes accepted by the Deck's Quickshell X11 loader.

A ProArt config-only reload cleared the transient missing-file error overlay; the recorded screenshot shows the banner absent. No cold or full native build was run. A full Nix compositor build, NixOS system build, activation, Deck deployment, and Deck service/session restart have **not** been performed.

Detailed command output and hashes are recorded outside the runtime tree at `~/.cache/steamdeck-config-reconcile/final-nix-loader-evidence.md`.
