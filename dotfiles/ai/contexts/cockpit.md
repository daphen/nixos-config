# Cockpit source

This repository is the current Cockpit implementation: a Quickshell window with
`TermView` on the left and the agentd-backed QML rail on the right. The desktop
bar/picker tree at `/home/daphen/nixos/dotfiles/quickshell` is a different
Quickshell application.

## Source map

| Area | Source |
| --- | --- |
| Window composition and rail | `qs-shell/shell.qml`, `qs-shell/Rail.qml` |
| agentd socket client | `qs-shell/AgentdState.qml` |
| embedded terminal | `TermView.cpp`, `TermView.h` |
| external status chin | `qs-shell/Chin.qml`, `/home/daphen/nixos/pkgs/neovim/lua/cockpit/chin.lua` |
| phone bridge | `bridge/`, `web/` |
| launch path | `run-qs.sh`; desktop callers are `/home/daphen/nixos/dotfiles/niri/.config/niri/scripts/cockpit-boot` and `cockpit-new` |

Treat the source map above and current launchers as authoritative. The
`Inter-agent coordination` section of
`/home/daphen/personal/notes/storage/references/agent-rail.md` remains useful for
cross-session topology; its opening architecture, rail UX, dev-loop, and cycle
history describe retired implementations and are not routing guidance. Agent
supervision lives in `/home/daphen/personal/agentd`; system integration and
Neovim configuration live in `/home/daphen/nixos`.

## Validate without activation

- Build the existing development tree with
  `nice -n 10 ionice -c3 nix develop --command bash -lc 'cmake --build build -j2'`.
- Run `./validate-qml.sh` after QML changes. It loads a copied shell offscreen
  and does not touch a running Cockpit.
- Use `test/` entrypoints for the behavior they cover; do not substitute source
  greps for lifecycle behavior.

`run-qs.sh` is a launcher, not a validator: it terminates the matching
`COCKPIT_INSTANCE` before launch. QML hot-reloads in a development instance;
C++ plugin changes require a build and an explicitly approved restart of the
named Cockpit. Never restart production Cockpit or agentd merely to test a
source edit.
