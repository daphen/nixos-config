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

  home.activation.generateThemes = config.lib.dag.entryAfter ["writeBoundary"] ''
    echo "Generating themes..."
    if [ -f "$HOME/.config/themes/theme-manager.sh" ]; then
      cd "$HOME/.config/themes"
      ./theme-manager.sh generate dark || true
      ./theme-manager.sh apply dark || true
    fi
  '';
}
