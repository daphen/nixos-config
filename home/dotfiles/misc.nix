{ config, pkgs, ... }:

{
  # Miscellaneous Dotfiles - all configs from the shared dotfiles repo

  # Yazi file manager
  programs.yazi = {
    enable = true;
    enableFishIntegration = true;
  };

  xdg.configFile."yazi" = {
    source = ../../dotfiles-source/yazi/.config/yazi;
    recursive = true;
  };

  # Qutebrowser
  xdg.configFile."qutebrowser" = {
    source = ../../dotfiles-source/qutebrowser/.config/qutebrowser;
    recursive = true;
  };

  # Eww (widgets)
  xdg.configFile."eww" = {
    source = ../../dotfiles-source/eww/.config/eww;
    recursive = true;
  };

  # Kanata (keyboard remapping)
  xdg.configFile."kanata" = {
    source = ../../dotfiles-source/kanata/.config/kanata;
    recursive = true;
  };

  # Claude Code hooks and commands
  xdg.configFile."claude" = {
    source = ../../dotfiles-source/claude/.claude;
    recursive = true;
  };

  # Systemd user services
  xdg.configFile."systemd/user" = {
    source = ../../dotfiles-source/systemd/.config/systemd/user;
    recursive = true;
  };
}
