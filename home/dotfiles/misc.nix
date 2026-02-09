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
    source = ../../dotfiles/yazi/.config/yazi;
    recursive = true;
  };
  
  # Qutebrowser
  xdg.configFile."qutebrowser" = {
    source = ../../dotfiles/qutebrowser/.config/qutebrowser;
    recursive = true;
  };
  
  # Eww (widgets)
  xdg.configFile."eww" = {
    source = ../../dotfiles/eww/.config/eww;
    recursive = true;
  };
  
  # Kanata (keyboard remapping)
  xdg.configFile."kanata" = {
    source = ../../dotfiles/kanata/.config/kanata;
    recursive = true;
  };
  
  # Claude Code hooks and commands
  xdg.configFile."claude" = {
    source = ../../dotfiles/claude/.config/claude;
    recursive = true;
  };
  
  # Systemd user services
  xdg.configFile."systemd/user" = {
    source = ../../dotfiles/systemd/.config/systemd/user;
    recursive = true;
  };
  
  # Edit files in ~/nixos/dotfiles and changes take effect immediately!
}
