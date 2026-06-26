# NixOS Configuration

Multi-machine NixOS flake. System + home-manager + dotfiles all live in this
one repo. Niri (Wayland), a centralized theme system, Quickshell bar/pickers,
and a portable dev-env flake output for remote sandboxes.

For the desktop architecture (Quickshell, theme system, niri stacks, daemons),
see [`dotfiles/SYSTEM.md`](dotfiles/SYSTEM.md). This file is about the Nix
plumbing: how the repo is laid out, how dotfiles get linked, and how to bring
up a new machine.

## Repo layout

```
nixos/
├── flake.nix              # inputs, overlays, mkHost helper, nixosConfigurations, #dev-env output
├── flake.lock
├── secrets.nix            # gitignored; only sets the password-hash file path (see Secrets)
├── common/                # shared across all machines
│   ├── default.nix        #   system: bootloader, locale, users, system packages, services
│   ├── niri.nix audio.nix bluetooth.nix networking.nix
│   └── home/              # home-manager (imported per-user in flake.nix)
│       ├── default.nix    #   session vars, xdg, desktop entries; imports the rest
│       ├── symlinks.nix   #   ← the dotfiles wiring (mkOutOfStoreSymlink)
│       ├── programs.nix theme-system.nix notes-sync.nix niri-scripts.nix
├── machines/              # one dir per host
│   ├── proart/            #   default.nix + hardware-configuration.nix (committed)
│   ├── thinkpad/          #   default.nix + hardware-configuration.nix (committed)
│   └── zenbook/           #   default.nix only (commented out in flake.nix)
├── pkgs/                  # in-repo derivations
│   ├── neovim/            #   nvim wrapper (config baked in)
│   └── daphen-env/        #   the `#dev-env` portable shell for remote sandboxes
└── dotfiles/              # app configs, scripts, themes — symlinked in by home-manager
```

There is **no** `configuration.nix`, `modules/`, `home/home.nix`, or
`dotfiles-source` symlink — that was the original Arch-migration layout and is
long gone. `/etc/nixos/` is unused; always build from this flake.

## How dotfiles get linked

`common/home/symlinks.nix` is the single place that maps repo files into
`$HOME`. It uses `config.lib.file.mkOutOfStoreSymlink`, so the files are **not
copied into the Nix store** — instead you get a two-hop chain:

```
~/.config/niri/config.kdl
  → /nix/store/…-home-manager-files/.config/niri/config.kdl   (home-manager's store dir)
    → ~/nixos/dotfiles/niri/.config/niri/config.kdl            (the live, editable file)
```

Consequences:

- **Editing a file under `~/nixos/dotfiles/` takes effect immediately** — no
  rebuild. You only `rebuild` when changing *which* files are linked (i.e. when
  you edit `symlinks.nix` itself), or any other `.nix`.
- The nested `dotfiles/<tool>/.config/<tool>/…` layout *looks* like GNU Stow,
  but **home-manager does the linking, not stow**. Adding a new dotfile means
  adding a line to `xdg.configFile` (for `~/.config/…`) or `home.file` (for
  `$HOME`) in `symlinks.nix`, then rebuilding once.

Two known files are deliberately **not** symlinked (their apps rewrite them),
so they must be copied by hand on a fresh install:

- `~/.config/fish/fish_variables` — fish rewrites it constantly.
- 1Password / browser / Claude local state — per-machine, gitignored.

## How a build is assembled

`flake.nix`:

- defines overlays (`iwd` pin, `neovim` 0.11.6 pin, widevine, asusctl patch,
  and an `appsOverlay` that routes fast-moving apps through the `nixpkgs-apps`
  channel);
- `commonModules` applies those overlays, the niri flake module, the `common/`
  system modules, and wires home-manager in-process
  (`home-manager.nixosModules.home-manager`, `users.daphen = import ./common/home`);
- `mkHost` = `commonModules ++ [ ./machines/<host> ]`;
- `nixosConfigurations` currently exports **`proart`** and **`thinkpad`**
  (`zenbook` is commented out).

Home-manager is **integrated into the system build** — there is no standalone
`homeConfigurations` to switch separately. `nixos-rebuild switch` applies both.

## Building / updating

Always use `--flake` and the right host name:

```bash
sudo nixos-rebuild switch --flake ~/nixos#proart    # or #thinkpad
# fish abbreviation `rebuild` expands to this
```

Update inputs:

```bash
nix flake update                       # everything
nix flake update nixpkgs-apps          # just the fast-moving apps channel
```

## Bootstrapping a new machine → 1:1 parity

Assuming a fresh NixOS install (any minimal ISO, user `daphen` created, network
up). The steps below are what's needed beyond the repo itself, because some
things are intentionally *not* in git.

1. **Clone the repo.**
   ```bash
   git clone <repo-url> ~/nixos
   ```

2. **Add an SSH key that can read the private flake input.** `flake.nix` pulls
   `palette-daemon` over `git+ssh://git@github.com/daphen/palette-daemon`. Nix
   can't evaluate the flake without an SSH key that has access to that repo, so
   set up `~/.ssh` and add the key to GitHub *before* the first build. (On a
   machine that won't run the desktop, you can instead drop the
   `palette-daemon` input + its uses.)

3. **Create the machine entry.** If it's a brand-new host (not proart/thinkpad):
   ```bash
   sudo nixos-generate-config --show-hardware-config \
     > ~/nixos/machines/<host>/hardware-configuration.nix
   ```
   Add `machines/<host>/default.nix` (copy an existing one; set
   `networking.hostName`, hardware/GPU/sleep quirks), then register it in
   `flake.nix` under `nixosConfigurations`. Existing hosts already have their
   `hardware-configuration.nix` committed — reuse only on the same physical
   machine.

4. **Provision secrets** (gitignored, so they don't come from the clone):
   - `~/nixos/secrets.nix` — recreate it; it only points at the password hash
     file:
     ```nix
     { ... }: {
       users.users.daphen.hashedPasswordFile = "/etc/secrets/daphen-password-hash";
     }
     ```
   - `/etc/secrets/daphen-password-hash` — create it:
     ```bash
     mkpasswd -m sha-512 | sudo tee /etc/secrets/daphen-password-hash
     ```
     (Or drop `secrets.nix` and set a password with `passwd` — secrets aren't
     managed by sops/agenix here, just a plain root-owned file.)

5. **Build & switch.**
   ```bash
   sudo nixos-rebuild switch --flake ~/nixos#<host>
   ```
   This activates the system *and* home-manager (dotfiles get symlinked).

6. **Copy the hand-managed, gitignored bits** for full parity:
   - `~/.config/fish/fish_variables` (copy from the old machine / the repo's
     reference copy).
   - Sign in to **1Password**, then the browsers (Vivaldi/Helium profiles,
     Chrome) — profile data is per-machine and not in git.
   - **Claude Code** state lives under `~/.claude` (symlinked from
     `dotfiles/claude/.claude`); only `themes/` is tracked — re-auth and let
     transcripts/credentials regenerate.

7. **Clone the dev-source repos** that runtime services or your workflow expect
   (separate repos, not needed for the *system* to build but needed for parity
   of behavior):
   - `~/personal/notes/cli/` — the `notes-sync` user service runs
     `notes-cli -watch` from here.
   - `~/personal/palette-daemon`, `~/personal/wpm-daemon`,
     `~/personal/chromium-palette` — source for the daemons (the *built*
     artifacts come from the flake input / pinned pkg revs, so these are only
     for editing/rebuilding them).
   - `~/work/bastardkb-qmk` — Charybdis firmware fork.

8. **Reboot.** Auto-login to niri on TTY1; TTY2 is kept enabled for emergency
   access.

What you get "for free" from the rebuild (no manual step): every package, all
dotfiles, the theme system (activated via home-manager), niri + Quickshell,
kanata, the systemd-user services (notes-sync, etc.), and fonts.

## Troubleshooting

- **Never run `nixos-rebuild` without `--flake`.** Bare `nixos-rebuild` reads
  `/etc/nixos/configuration.nix`, which this system does not use.
- **First build fails on `palette-daemon`** → missing/insufficient SSH key for
  the private input (step 2).
- **Dotfiles not appearing** → check `readlink -f ~/.config/<tool>`; it should
  resolve through the store into `~/nixos/dotfiles/...`. If not, the entry is
  missing from `symlinks.nix` or the rebuild didn't run.
- **Validate / inspect**: `nix flake check`, `nix flake show`.
- **Recover**: pick a previous generation from the systemd-boot menu.

## Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Niri](https://github.com/YaLTeR/niri)
- [Search Packages](https://search.nixos.org)
