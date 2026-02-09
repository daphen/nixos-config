{ config, pkgs, ... }:

{
  # Waybar Configuration
  # ====================
  
  programs.waybar = {
    enable = true;
    systemd.enable = true;
  };
  
  # Copy Waybar configuration and styles from dotfiles
  xdg.configFile."waybar" = {
    source = ../../dotfiles/waybar/.config/waybar;
    recursive = true;
  };
  
  # Waybar includes:
  # - config: Main waybar configuration
  # - style.css: Waybar styling
  # - scripts/: Custom scripts for waybar modules
  #   - audio menu
  #   - niri workspace minimap
  # 
  # Edit files in ~/nixos/dotfiles/waybar and changes take effect immediately!
}
