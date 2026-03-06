{ config, pkgs, ... }:

{
  # Terminal Emulators - install packages, configs live in dotfiles

  # Kitty (primary terminal)
  programs.kitty.enable = true;

  xdg.configFile."kitty" = {
    source = ../../dotfiles-source/kitty/.config/kitty;
    recursive = true;
  };

  # WezTerm
  programs.wezterm.enable = true;

  xdg.configFile."wezterm" = {
    source = ../../dotfiles-source/wezterm/.config/wezterm;
    recursive = true;
  };

  # Alacritty (no config in dotfiles yet - will use defaults)
  programs.alacritty.enable = true;

  # Tmux
  programs.tmux.enable = true;

  xdg.configFile."tmux" = {
    source = ../../dotfiles-source/tmux/.config/tmux;
    recursive = true;
  };
}
