# Theme system - activation script for generating themes on switch
# The theme files themselves are symlinked via symlinks.nix
{ config, pkgs, ... }:
let
  themectl = pkgs.callPackage ../../pkgs/themectl {};
in {
  home.packages = [ themectl pkgs.jq ];

  home.activation.generateThemes = config.lib.dag.entryAfter ["writeBoundary"] ''
    if [ -f "$HOME/.config/themes/theme-manager.sh" ]; then
      echo "Regenerating themes from the system preference..."
      ${themectl}/bin/themectl auto
    fi
  '';
}
