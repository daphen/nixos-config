{ config, pkgs, ... }:

{
  # Waybar Configuration
  # ====================
  
  programs.waybar = {
    enable = true;
    # systemd integration
    systemd.enable = true;
  };
  
  # Copy Waybar configuration and styles from dotfiles
  xdg.configFile."waybar" = {
    source = ../../dotfiles-source/waybar;
    recursive = true;
  };
  
  # Waybar includes:
  # - config: Main waybar configuration
  # - style.css: Waybar styling
  # - scripts/: Custom scripts for waybar modules
  #   - wifi menu
  #   - audio menu
  #   - niri workspace minimap
}
