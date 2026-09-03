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
      # Keep the rail commands that legacy heidr-* compatibility symlinks target.
      for script in $out/bin/cockpit-*; do
        case "$(basename "$script")" in
          cockpit-app|cockpit-cross|cockpit-ipc|cockpit-rail|cockpit-rail-focus|cockpit-rail-lovbox|cockpit-rail-lovbox-connect|cockpit-rail-roster) ;;
          *) rm -f "$script" ;;
        esac
      done
      # chmod only regular files — `chmod +x $out/bin/*` chokes on a stray/dangling
      # symlink (a `bash -> /run/current-system/…` symlink once broke this build).
      find $out/bin -type f -exec chmod +x {} +
      patchShebangs $out/bin
    '';
  };
in {
  home.packages = [ niri-scripts ];
}
