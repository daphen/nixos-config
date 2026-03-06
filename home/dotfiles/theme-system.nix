{ config, pkgs, ... }:

let
  theme-generator = pkgs.writeShellScriptBin "theme-manager" ''
    #!/usr/bin/env bash
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

  # Theme system files from the shared dotfiles repo
  xdg.configFile."themes" = {
    source = ../../dotfiles-source/themes;
    recursive = true;
  };

  # Generate themes on home-manager switch
  home.activation.generateThemes = config.lib.dag.entryAfter ["writeBoundary"] ''
    echo "Generating themes..."

    if [ -f "$HOME/.config/themes/theme-manager.sh" ]; then
      cd "$HOME/.config/themes"
      ./theme-manager.sh generate dark || true
      ./theme-manager.sh apply dark || true
    fi
  '';
}
