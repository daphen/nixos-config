# proart system architecture

A map of the major subsystems on this NixOS machine, where their code lives, and
how they talk to each other. Aimed at an agent landing fresh and trying to
figure out what to touch for a given task.

## At a glance

```
niri compositor
├─ keybinds and launchers     dotfiles/niri/.config/niri/
├─ desktop Quickshell         dotfiles/quickshell/.config/quickshell/
│  └─ bar, minimap, notifications, pickers
└─ two stable Cockpit windows launch through cockpit-boot

Cockpit source                ~/personal/ai-cockpit
├─ Quickshell rail            qs-shell/
├─ embedded Neovim terminal   TermView.cpp / TermView.h
└─ agent sessions             unix socket → agentd → pi --mode rpc

system and Home Manager       flake.nix + common/ + machines/
themes                        dotfiles/themes + pkgs/themectl
```

## Repositories

| Repo                    | Where                         | What                                                                                                                                      |
| ----------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `nixos-config`          | `~/nixos`                     | System + home-manager config, dotfiles, and the `#dev-env` flake output for sandboxes                                                     |
| `dotfiles`              | `~/nixos/dotfiles`            | App configs, scripts, themes (now a subtree of nixos-config, not a standalone repo)                                                       |
| `nixos-portable-config` | `~/nixos-portable-config`     | Retired — fully replaced by `nix run github:daphen/nixos-config#dev-env`. No remaining references; the repo + local clone can be deleted. |
| `palette-daemon`        | `~/personal/palette-daemon`   | Rust + webkit6                                                                                                                            |
| `chromium-palette`      | `~/personal/chromium-palette` | Solid app served by palette-daemon                                                                                                        |
| `newtab`                | `~/personal/newtab`           | React infinite-canvas NTP extension (owns chrome://newtab)                                                                                |
| `wpm-daemon`            | `~/personal/wpm-daemon`       | Rust evdev daemon                                                                                                                         |
| `ai-cockpit`            | `~/personal/ai-cockpit`       | Current Quickshell Cockpit, embedded terminal, rail, and phone bridge                                                                     |
| `agentd`                | `~/personal/agentd`           | Go supervisor for scoped Pi sessions                                                                                                      |
| `bastardkb-qmk`         | `~/work/bastardkb-qmk`        | Charybdis firmware fork                                                                                                                   |

## Live vs baked — do I rebuild?

Two mechanisms deliver config to the running system:

- **Live** (`mkOutOfStoreSymlink`, in `common/home/symlinks.nix`) — the
  `~/.config` entry points straight at the repo working tree. Edit →
  reload/restart the app. **No `nixos-rebuild`.** Covers most app config: fish,
  kitty, git, yazi, qutebrowser, quickshell, niri (`config.kdl` + scripts),
  themes, starship, kanata, opencode, `~/.claude` (skills/commands →
  `dotfiles/claude`), `~/.local/bin/agent` (agentd coordination CLI).
- **Baked** (copied into the Nix store) — needs `nixos-rebuild`. Packages + the
  system: `home.packages`, module definitions, `configuration.nix`, flake
  inputs, and the Rust daemons (palette/wpm — rebuild + restart the service).

**neovim is the trap.** It lives at `~/nixos/pkgs/neovim/` (NOT `dotfiles/`) and
is split:

- `lua/`, `colors/`, `rules/`, `snippets/` → **live** (symlinked to
  `~/.config/nvim`; proart's `nvim` runs the `nvimLocal`/`test_mode` wrapper
  that reads it off disk). Edit → **just restart nvim.**
- `default.nix` (the package — plugins, treesitter grammars, LSP/PATH tools,
  pinned binary) → **baked.** Edit → `nixos-rebuild`.

Portability is intact: `nix run github:daphen/nixos-config#neovim` runs the
**baked** build (lua copied into the store) — same build sandboxes get
(`daphen-env`) and what `nvim-next` runs locally. The baked copy updates on
**push**, not a local rebuild (except `nvim-next`). proart's `nvim` is the live
wrapper for zero-rebuild iteration.

Rule of thumb: **a config file in a symlinked dir → reload the app; anything
that defines a package or the system → rebuild.**

## Quickshell architecture

`~/nixos/dotfiles/quickshell/.config/quickshell/`

- `shell.qml` — root. Uses `Variants { model: Quickshell.screens }` so bar +
  NotificationOverlay reconcile across monitor docks/undocks (don't use
  imperative `Component.onCompleted` for per-screen surfaces).
- `wallpaper/shell.qml` — separate Quickshell instance owning the background
  surfaces, so reloading bar, picker, or notification QML cannot flash the
  compositor backdrop.
- `modules/qmldir` — registers every component.
- `modules/Bar.qml` — top-of-screen bar. Leftmost = `wpmPill`, middle =
  `Minimap`, rightmost = `worktreePill`. Mid bar = leftGroup (DateText, Weather,
  Cpu, Memory) + rightGroup (Inbox, Dnd, Network, Audio, Battery, Clock).
- `modules/*State.qml` — singletons holding state. Most consumed by pickers;
  `NiriState.qml` is the most important (subscribes to niri's event-stream and
  exposes `version`, `focusedAppId()`, `focusedOutput()`,
  `minimapEntries(output)`).
- `modules/*Picker.qml` + matching `*PickerState.qml` — IPC-toggleable fzf-style
  pickers (emoji, network, bluetooth, color-format, lovbox, worktree,
  claude-rename, asus-profile). Each registers an
  `IpcHandler { target: "<name>" }` so niri keybinds open them with
  `qs ipc call <name> toggle`.
- `modules/Notifications.qml` — singleton wrapping `NotificationServer`. Handles
  DND, focus-dismiss, kitty OSC dedupe by body+summary.
- `modules/NotificationOverlay.qml` — toast strip; visibility gated on
  `screen.name === NiriState.focusedOutput()` so toasts only appear on the
  active monitor.

## Voice dictation

Hold `Super+V` to record and release it to transcribe. Niri sends `PttDown` to
OpenWhispr's session D-Bus service; OpenWhispr's evdev listener observes the key
release, runs local transcription and cleanup, then pastes through `uinput`.

`openwhispr.service` owns the app and removes stale state on exit. Confirmed
lifecycle changes are written atomically to
`$XDG_RUNTIME_DIR/openwhispr-dictation-state`; `DictationState.qml` watches that
file and `DictationOverlay.qml` maps the click-through bottom-center ThinkingOrb.
Models and provider choices remain in OpenWhispr's settings. For recovery, check
`systemctl --user status openwhispr`, D-Bus name `com.openwhispr.App`, membership
in `input`, `uinput`, and `ydotool`, then the runtime state file.

## Theme system

`~/nixos/dotfiles/themes/.config/themes/`

- `org.gnome.desktop.interface color-scheme` — the sole light/dark preference;
  `prefer-dark` selects dark, while `prefer-light` and `default` select light.
  `themectl switch light|dark` and `toggle_theme` only change this setting.
- Desktop `shell.qml` owns one `themectl-watch` child. Its native GSettings
  subscription immediately publishes `theme_mode`, then runs `themectl auto`
  asynchronously. Generation and browser builds cannot block that notification.
  Only one application runs at a time; changes during it request one follow-up
  using the current preference, not a queue of old modes. The renderer never
  writes the notification file or the preference and rechecks the preference
  after slow adapters finish.
- `~/.config/theme_mode` — generated output for existing Quickshell, wallpaper,
  Neovim and Fish readers, never an input for choosing the system preference.
  Fish refreshes colors on the next prompt; startup/activation cannot select a
  different mode. Already-running apps with explicit overrides may need their
  own theme setting changed to system-following.
- `colors.json` — the two color palettes (dark + light).
- `templates/<tool>.template` — Mustache-ish placeholders like
  `{{background.primary}}`.
- `theme-processor.py` — substitutes placeholders →
  `generated/<tool>/<mode>.theme`.
- `theme-manager.sh apply` — applies generated themes matching the global
  preference. `auto` generates first; `generate dark|light` also works offline.
  Existing adapters update app configuration and `theme_mode` without restarting
  the desktop portal. Identical generated QML is not rewritten, avoiding reload
  loops when the desktop follower starts.

### Steam Big Picture (CSS Loader)

`templates/steam-css-loader.template` renders both palettes through the normal
processor. The Steam adapter copies the current palette to
`~/homebrew/themes/Dotfiles/shared.css` alongside the v8 `theme.json` manifest
from `templates/steam-css-loader/`. This is a CSS Loader bundle, not a legacy
Steam `skins/` directory; it targets Big Picture, Quick Access, and the main
menu.

On the Deck, Jovian installs Decky automatically using `~/homebrew` as its state
directory. Install CSS Loader from Decky's store and enable **Dotfiles** once.
Use CSS Loader's theme reload if palette edits are not reflected immediately.
Steam UI class changes may require updating the template's selectors; actual
Deck rendering remains a hardware check. Workstation Decky/CSS Loader installs
are separate from the Deck's NixOS configuration.

### FZF special-case

We use `FZF_DEFAULT_OPTS_FILE` (not `FZF_DEFAULT_OPTS` env var) so theme toggles
take effect live in already-running processes (yazi, claude TUI, etc). Flow:

1. Template produces a plain `--color=...` lines file (one flag per line, no
   shell wrapper).
1. `theme-manager.sh apply` symlinks `~/.config/fzf/opts.conf` →
   `~/.config/themes/generated/fzf/<mode>.theme`.
1. `FZF_DEFAULT_OPTS_FILE=~/.config/fzf/opts.conf` is exported via home-manager
   `home.sessionVariables` (and `niri.environment{}` for compositor-spawned
   commands).
1. fzf reads the file on every invocation → instant toggle.

`fish/.config/fish/conf.d/zz_strip_fzf_default_opts.fish` defensively unsets any
inherited `FZF_DEFAULT_OPTS` (which would override the file).

## Niri and Cockpit contexts

`~/nixos/dotfiles/niri/.config/niri/` owns compositor configuration and desktop
launchers. The former workspace-per-stack and fixed kitty Cockpit flows are
retired; do not use the remaining `ws-*` files as architecture.

Current entrypoints:

- `cockpit-boot work|personal` restores one of two stable Cockpit instances.
- `cockpit-new` creates a unique personal instance.
- `vm-wt EVERY-N` creates the VM worktree/mirror and worker session.
- `agent-review <PR>` owns PR review checkout and session creation.
- Super+T focuses the rail roster; Super+Ctrl+T opens its context picker.

These scripts launch `/home/daphen/personal/ai-cockpit/run-qs.sh`. The desktop
Quickshell tree remains responsible for the bar, notifications, and global
pickers only.

## Hyprland canvas

`~/nixos/dotfiles/hyprland/.config/hypr/` is the canonical Hyprland desktop:
`hyprland.lua` owns the canvas layout and compositor configuration, while
`scripts/` contains Hyprland-only ports of the desktop launchers. It must not
source or execute files under `.config/niri`; shared behavior is copied only
when it has an independent Hyprland entrypoint.

Home Manager maps this tree to `~/.config/hypr/`. From a Linux TTY, run
`hypr-session` to start the canvas directly; Niri need not be running. The old
`~/hypr-real` entrypoint still works. Both load the canonical config directly.
When handing over from an active Niri session, the launcher restores Niri on
exit; a standalone launch returns to the TTY instead.

## Notifications

- `Notifications.qml` registers `NotificationServer`
  (org.freedesktop.Notifications).
- On arrival: DND check, then kitty dedupe (same body + workspace-tagged summary
  preferred over generic).
- On focus change: matching app's notifs auto-dismiss (via `appIdToNotifAppName`
  mapping). Kitty notifs use a workspace check so only the focused-workspace's
  kitty notifs dismiss.
- Endcord's `notification_in_active = False` + CSI 1004 focus reporting handle
  the "active chat + window unfocused" case at the source. Note: our fork
  patches `tui.py` to handle ncurses' translated focus keycodes 590/591 (the raw
  `ESC[I/O` byte form never arrives in keypad mode).

## Charybdis firmware

`~/work/bastardkb-qmk/keyboards/bastardkb/charybdis/3x6/keymaps/daphen/`

Custom keymap.c is minimal (BASE/LOWER/RAISE — VIA holds the real keymap in
dynamic EEPROM). Key tunings in `config.h`:

- `HOLD_ON_OTHER_KEY_PRESS` + `HOLD_ON_OTHER_KEY_PRESS_PER_KEY` (per-key escape
  hatch for `LT(3, KC_DOT)` — slow pinky).
- `PERMISSIVE_HOLD` + `TAPPING_TERM 175`.
- `MOUSE_DISABLE_AFTER_KEYPRESS_MS 100` — trackball pauses briefly after each
  keypress.

Firmware-level patches in `charybdis.c` (our fork at `~/work/bastardkb-qmk` is
on `bkb-master`):

- `pointing_device_init_kb()` — re-applies saved DPI on every pointing-device
  reinit (USB resume etc), fixes the "trackball resets to 1600 CPI after
  suspend" symptom.

VIA layout backup: `~/nixos/dotfiles/via/charybdis-mini-via.json`.

## Daemons running on this machine

| Daemon                   | Purpose                                                | Started by                              |
| ------------------------ | ------------------------------------------------------ | --------------------------------------- |
| `niri`                   | Compositor                                             | systemd graphical-session               |
| `quickshell`             | Bar / notifications / pickers                          | niri spawn-at-startup                   |
| `quickshell` (wallpaper) | Isolated wallpaper surfaces                            | niri spawn-at-startup                   |
| `palette-daemon`         | Cmd-palette overlay                                    | systemd-user (graphical-session.target) |
| `wpm-daemon`             | Bar WPM counter                                        | systemd-user (graphical-session.target) |
| `openwhispr`             | Local voice dictation + transcript paste               | systemd-user (graphical-session.target) |
| `kanata`                 | Key remap                                              | NixOS system service                    |
| `mako`                   | (removed; replaced by Quickshell's NotificationServer) | —                                       |
| `blueman-applet`         | (removed; deduped bluetooth notifs)                    | —                                       |
| `ws-tracker`             | Active workspace pointer                               | systemd-user                            |

## plan-ticket workflow

The tracked skill at `dotfiles/ai/skills/plan-ticket/` owns the plan → finalize
→ implement → reconcile lifecycle for Pi workers. It writes the plan Markdown,
progress JSON, and review JSON to `~/personal/notes/storage/plans/` when the
real vault exists; VM workers use a gitignored `.plans/` directory.

`pkgs/neovim/lua/plan-nvim/` renders those artifacts. Its lifecycle actions
route `/plan-ticket --<phase>` through the `agent` CLI to the session bound to
the plan, preferring an exact session name and falling back to repo cwd. It no
longer injects commands into a Claude TUI or uses `wt-send`.

The skill is available only when the active role profile includes it; profile
allowlists are declared in `dotfiles/ai/roles/manifest.json`. Neovim Lua is
live-linked but cached, so plugin changes need a deliberate Neovim restart, not
a system rebuild.

## Where to look for a given task

- **Bar widget change** →
  `~/nixos/dotfiles/quickshell/.config/quickshell/modules/Bar.qml` + new
  `Foo.qml` and `FooState.qml`, register in `qmldir`.
- **Theme tweak** → `~/nixos/dotfiles/themes/.config/themes/colors.json` or
  `templates/<tool>.template`; the public `theme-manager.sh` wrapper delegates
  to `themectl`.
- **Niri keybind** → `~/nixos/dotfiles/niri/.config/niri/config.kdl`
  (live-linked).
- **Niri spawn script** → `~/nixos/dotfiles/niri/.config/niri/scripts/<name>`.
- **Notification routing** → `Notifications.qml` `onNotification` handler + the
  `appIdToNotifAppName` map.
- **Charybdis firmware** → `~/work/bastardkb-qmk/...`, build with
  `nix-shell -p qmk --run 'qmk compile -kb bastardkb/charybdis/3x6 -km daphen'`,
  flash both halves separately.
- **WPM tuning** → `~/personal/wpm-daemon/src/main.rs` — knobs at the top
  (`PAUSE_THRESHOLD`, `MIN_BURST_CHARS`, `DISPLAY_HOLD`). Rebuild + restart
  service.
- **neovim config / lua** → `~/nixos/pkgs/neovim/lua/` (restart nvim, no
  rebuild). Plugins/grammars/tools → `~/nixos/pkgs/neovim/default.nix`
  (rebuild).
- **Cockpit rail or terminal** → `~/personal/ai-cockpit/`; read its `AGENTS.md`
  and the rail reference before editing.
- **agentd** → `~/personal/agentd/`; read its `AGENTS.md` before editing or
  considering activation.
- **plan workflow** → tracked skill `~/nixos/dotfiles/ai/skills/plan-ticket/` +
  plugin `~/nixos/pkgs/neovim/lua/plan-nvim/`. See the plan-ticket section
  above.
