# Niri scripts - packaged as a derivation for PATH availability
# The niri config.kdl itself is symlinked via symlinks.nix
{ config, pkgs, inputs, ... }:
let
  # Source from the flake itself (a pure store path), NOT an absolute ~/… path.
  # A derivation `src` must be readable at build time; an out-of-flake absolute
  # path is forbidden in pure flake eval, and the old `~/dotfiles` didn't even
  # exist (dotfiles live at ~/nixos/dotfiles) — so this package silently stopped
  # picking up new/changed scripts. `inputs.self` tracks every git-tracked file.
  niri-scripts = pkgs.stdenv.mkDerivation {
    name = "niri-scripts";
    src = "${inputs.self}/dotfiles/niri/.config/niri/scripts";

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
