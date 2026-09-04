# proart system source

This repository owns the NixOS flake, integrated Home Manager configuration,
in-repo packages, and desktop dotfiles. Read `README.md` for flake assembly and
`dotfiles/SYSTEM.md` for the current subsystem map before changing system or
desktop behavior.

## Route by subsystem

| Work | Read first | Source |
| --- | --- | --- |
| Host or Home Manager | `README.md` | `flake.nix`, `common/`, `machines/` |
| Desktop architecture | `dotfiles/SYSTEM.md` | `dotfiles/`, `common/home/symlinks.nix` |
| Niri | Niri section in `dotfiles/SYSTEM.md` | `dotfiles/niri/.config/niri/` |
| Bar, pickers, notifications | Quickshell section in `dotfiles/SYSTEM.md` | `dotfiles/quickshell/.config/quickshell/` |
| Themes | Theme section in `dotfiles/SYSTEM.md` | `dotfiles/themes/.config/themes/`, `pkgs/themectl/` |
| Neovim | Neovim section in `dotfiles/SYSTEM.md` | `pkgs/neovim/` |
| Cockpit | `/home/daphen/personal/ai-cockpit/AGENTS.md` | separate `ai-cockpit` repository |
| agentd | `/home/daphen/personal/agentd/AGENTS.md` | separate `agentd` repository |

The desktop Quickshell tree is not Cockpit. Current Cockpit launchers in
`dotfiles/niri/.config/niri/scripts/cockpit-*` enter
`/home/daphen/personal/ai-cockpit`.

## Validation and activation

- Files mapped by `common/home/symlinks.nix` are live working-tree links. Inspect
  that file before deciding whether a rebuild is necessary.
- Validate system changes without activation using
  `nice -n 10 ionice -c3 nix build .#nixosConfigurations.proart.config.system.build.toplevel --no-link`.
- Activate only with David's explicit approval:
  `/run/wrappers/bin/sudo nixos-rebuild switch --flake /home/daphen/nixos#proart`.
  This switches NixOS and Home Manager together; never run bare
  `nixos-rebuild` and never reboot as part of validation.
- A live-linked QML, KDL, Lua, or unit edit still needs its real isolated loader
  check before reporting success. Do not restart a visible Cockpit, daemon, or
  desktop service without explicit approval.

Preserve unrelated dirty work. Verify current source and launchers rather than
copying commands from historical notes.
