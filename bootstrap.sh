#!/usr/bin/env bash
# Bootstrap the portable dev environment on a fresh Linux container/server.
#
# Run on any Linux host with network access:
#   curl -L https://raw.githubusercontent.com/daphen/nixos-config/main/bootstrap.sh | bash
#
# What this does:
#   1. Installs Nix (multi-user) via the Determinate installer if missing
#   2. Enables flakes + nix-command
#   3. Runs home-manager switch against homeConfigurations.daphen-remote
#      from github:daphen/nixos-config
#
# After: fish, nvim, starship, git, claude-code, opencode, and the CLI toolkit
# are installed and ready. Plugins for nvim are pre-installed (baked into the
# Nix store) so the first `nvim` launch is instant.
#
# Authentication (one-time per host, not automated):
#   - 1Password: op signin
#   - git: set up SSH key or use ssh-agent forwarding
#   - claude / opencode: first-run interactive or env vars

set -euo pipefail

readonly FLAKE_URL="${FLAKE_URL:-github:daphen/nixos-config}"
readonly HM_ATTR="${HM_ATTR:-daphen-remote}"

info() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m==>\033[0m %s\n" "$*" >&2; }
fail() { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; exit 1; }

# ── 1. Install Nix if missing ────────────────────────────────────────────
if ! command -v nix >/dev/null 2>&1; then
  info "Nix not found — installing via the Determinate installer"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm

  # Source the nix profile into the current shell so subsequent commands see it
  if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi

  if ! command -v nix >/dev/null 2>&1; then
    fail "Nix install appeared to succeed but 'nix' is still not on PATH. Open a new shell and re-run."
  fi
else
  info "Nix already installed: $(nix --version)"
fi

# ── 2. Ensure flakes + nix-command are enabled for this invocation ────────
export NIX_CONFIG="experimental-features = nix-command flakes"

# ── 3. Run home-manager switch ────────────────────────────────────────────
info "Running home-manager switch --flake ${FLAKE_URL}#${HM_ATTR}"
info "(first run on a new host downloads ~1-2 GB from the Nix binary cache)"

nix run home-manager/master -- switch \
  --flake "${FLAKE_URL}#${HM_ATTR}" \
  -b backup \
  "$@"

info "Bootstrap complete."
info ""
info "Next steps (one-time per host):"
info "  1) Auth 1Password:    op signin"
info "  2) Set up git:         ssh-add -l  # ensure an SSH key is forwarded, or add one"
info "  3) Auth claude/opencode on first run"
info ""
info "Type 'fish' to enter the shell. 'nvim' opens with all plugins pre-installed."
