{ config, pkgs, ... }:

{
  # Miscellaneous Dotfiles
  # ======================
  
  # Yazi file manager
  programs.yazi = {
    enable = true;
    enableFishIntegration = true;
  };
  
  xdg.configFile."yazi" = {
    source = ../../dotfiles-source/yazi;
    recursive = true;
  };
  
  # Qutebrowser
  xdg.configFile."qutebrowser" = {
    source = ../../dotfiles-source/qutebrowser;
    recursive = true;
  };
  
  # Eww (widgets)
  xdg.configFile."eww" = {
    source = ../../dotfiles-source/eww;
    recursive = true;
  };
  
  # Kanata (keyboard remapping)
  xdg.configFile."kanata" = {
    source = ../../dotfiles-source/kanata;
    recursive = true;
  };
  
  # Claude Code hooks and commands
  xdg.configFile."claude" = {
    source = ../../dotfiles-source/claude;
    recursive = true;
  };
  
  # Swaylock
  xdg.configFile."swaylock" = {
    source = ../../dotfiles-source/swaylock;
    recursive = true;
  };
  
  # Additional config files that don't have dedicated programs
  # XCompose for custom character compositions
  home.file.".XCompose" = {
    source = ../../dotfiles-source/misc/XCompose;
  };
  
  # Systemd user services
  # These will be copied from ~/dotfiles/systemd/.config/systemd/user/
  xdg.configFile."systemd/user" = {
    source = ../../dotfiles-source/systemd/user;
    recursive = true;
  };
}
