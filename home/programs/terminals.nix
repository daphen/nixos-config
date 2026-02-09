{ config, pkgs, ... }:

{
  # Terminal Emulators Configuration
  # =================================

  # Kitty (primary terminal)
  programs.kitty = {
    enable = true;
    font = {
      name = "BerkeleyMono Nerd Font";
      size = 13;
    };
  };

  # WezTerm
  programs.wezterm = {
    enable = true;
    # Copy WezTerm config from dotfiles
  };
  
  xdg.configFile."wezterm" = {
    source = ../../dotfiles/wezterm/.config/wezterm;
    recursive = true;
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
