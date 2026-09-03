# Theme system - activation script for generating themes on switch
# The theme files themselves are symlinked via symlinks.nix
{ config, pkgs, ... }:
let
  themectl = pkgs.callPackage ../../pkgs/themectl {};
in {
  home.packages = [ themectl pkgs.jq ];

  # Regenerate + reapply themes on every activation. Pre-rebuild this hook
  # always applied `dark` regardless of state, which flipped any tool whose
  # config is written *outside* a HM-managed directory (claude-code,
  # starship.toml, etc.) to dark while HM-managed configs (kitty) kept
  # whatever was in dotfiles. Honor ~/.config/theme_mode so the
  # active mode wins on rebuild.
  home.activation.generateThemes = config.lib.dag.entryAfter ["writeBoundary"] ''
    if [ -f "$HOME/.config/themes/theme-manager.sh" ]; then
      mode="$(cat "$HOME/.config/theme_mode" 2>/dev/null || echo dark)"
      echo "Regenerating themes for $mode mode..."
      ${themectl}/bin/themectl generate "$mode" || true
      ${themectl}/bin/themectl apply "$mode" || true
    fi
  '';
}
