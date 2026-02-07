{ config, pkgs, ... }:

{
  # Terminal Emulators Configuration
  # =================================

  # Ghostty (primary terminal)
  xdg.configFile."ghostty/config" = {
    source = ../../dotfiles-source/ghostty/config;
  };

  # WezTerm
  programs.wezterm = {
    enable = true;
    # Copy WezTerm config from dotfiles
  };
  
  xdg.configFile."wezterm" = {
    source = ../../dotfiles-source/wezterm;
    recursive = true;
  };

  # Kitty
  programs.kitty = {
    enable = true;
    # Basic Kitty settings, can be expanded
    font = {
      name = "BerkeleyMono Nerd Font";
      size = 13;
    };
  };

  # Alacritty
  programs.alacritty = {
    enable = true;
    settings = {
      font = {
        normal = {
          family = "BerkeleyMono Nerd Font";
          style = "Regular";
        };
        size = 13;
      };
    };
  };

  # Tmux
  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    keyMode = "vi";
    customPaneNavigationAndResize = true;
    
    extraConfig = ''
      # Copy your tmux.conf settings here
      # Or source from dotfiles
      
      # Example: Rose Pine theme colors
      set -g status-bg "#121212"
      set -g status-fg "#ededed"
    '';
  };
}
