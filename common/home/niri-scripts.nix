# Niri scripts - packaged as a derivation for PATH availability
# The niri config.kdl itself is symlinked via symlinks.nix
{ config, pkgs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";

  niri-scripts = pkgs.stdenv.mkDerivation {
    name = "niri-scripts";
    src = "${dotfiles}/niri/.config/niri/scripts";

    buildInputs = with pkgs; [
      bash coreutils jq grim slurp
      wl-clipboard yazi zoxide fzf
    ];

    installPhase = ''
      mkdir -p $out/bin
      cp -r $src/* $out/bin/
      chmod +x $out/bin/*
      patchShebangs $out/bin
    '';
  };
in {
  home.packages = [ niri-scripts ];
}
