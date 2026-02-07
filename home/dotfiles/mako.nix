{ config, pkgs, ... }:

{
  # Mako Notification Daemon Configuration
  # =======================================
  
  services.mako = {
    enable = true;
    
    # Basic settings
    defaultTimeout = 5000;
    ignoreTimeout = false;
    
    # Positioning
    anchor = "top-right";
    
    # Appearance (Rose Pine theme colors)
    backgroundColor = "#0A0A0A";
    textColor = "#EDEDED";
    borderColor = "#2A2F39";
    progressColor = "over #6A8BE3";
    
    borderSize = 2;
    borderRadius = 8;
    
    # Font
    font = "BerkeleyMono Nerd Font 11";
    
    # Size
    width = 350;
    height = 150;
    margin = "20";
    padding = "15";
    
    # Icons
    icons = true;
    maxIconSize = 48;
    
    # Grouping
    groupBy = "app-name";
    
    # Additional settings from your mako config will be added here
  };
  
  # Alternative: Copy entire mako config if it has complex settings
  # xdg.configFile."mako/config" = {
  #   source = ../../dotfiles-source/mako/config;
  # };
}
