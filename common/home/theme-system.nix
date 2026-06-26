# Theme system - activation script for generating themes on switch
# The theme files themselves are symlinked via symlinks.nix
{ config, pkgs, ... }:
let
  theme-generator = pkgs.writeShellScriptBin "theme-manager" ''
    THEMES_DIR="$HOME/.config/themes"
    if [ -f "$THEMES_DIR/theme-manager.sh" ]; then
      cd "$THEMES_DIR"
      exec ./theme-manager.sh "$@"
    else
      echo "Theme manager not found at $THEMES_DIR/theme-manager.sh"
      exit 1
    fi
  '';
in {
  home.packages = [ theme-generator pkgs.jq ];

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
      cd "$HOME/.config/themes"
      ./theme-manager.sh generate "$mode" || true
      ./theme-manager.sh apply "$mode" || true
    fi
  '';
}
