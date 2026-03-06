{ config, pkgs, ... }:

{
  # Waybar - enable program, config lives in dotfiles
  programs.waybar = {
    enable = true;
    systemd.enable = true;
  };

  xdg.configFile."waybar" = {
    source = ../../dotfiles-source/waybar/.config/waybar;
    recursive = true;
  };
}
