{ config, pkgs, ... }:

let
  # Create a derivation for Niri scripts
  # This ensures they're properly packaged with dependencies
  niri-scripts = pkgs.stdenv.mkDerivation {
    name = "niri-scripts";
    src = ../../dotfiles-source/niri/.config/niri/scripts;

    buildInputs = with pkgs; [
      bash
      coreutils
      jq
      grim
      slurp
      wl-clipboard
      ghostty
      yazi
      zoxide
      fzf
    ];

    installPhase = ''
      mkdir -p $out/bin

      # Copy all scripts
      cp -r $src/* $out/bin/

      # Make all scripts executable
      chmod +x $out/bin/*

      # Patch shebangs
      patchShebangs $out/bin
    '';
  };

in {
  # Add niri-scripts to user packages
  home.packages = [ niri-scripts ];

  # Niri config from the shared dotfiles repo
  xdg.configFile."niri/config.kdl" = {
    source = ../../dotfiles-source/niri/.config/niri/config.kdl;
  };
}
