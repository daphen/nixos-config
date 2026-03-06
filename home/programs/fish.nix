{ config, pkgs, ... }:

{
  # Fish Shell
  # Only enable the program and integrations - config lives in dotfiles
  programs.fish.enable = true;

  # FZF integration (installs fzf + wires fish keybindings)
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };

  # Zoxide (smart cd)
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  # All fish config files come from the shared dotfiles repo
  xdg.configFile = {
    "fish/config.fish" = {
      source = ../../dotfiles-source/fish/.config/fish/config.fish;
    };
    "fish/functions" = {
      source = ../../dotfiles-source/fish/.config/fish/functions;
      recursive = true;
    };
    "fish/conf.d" = {
      source = ../../dotfiles-source/fish/.config/fish/conf.d;
      recursive = true;
    };
  };
}
