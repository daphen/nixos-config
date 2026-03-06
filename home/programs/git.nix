{ config, pkgs, ... }:

{
  # Git - install packages, config lives in dotfiles
  programs.git.enable = true;

  # GitHub CLI
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
      editor = "nvim";
    };
  };

  # Lazygit
  programs.lazygit.enable = true;

  # Git config files from the shared dotfiles repo
  # .gitconfig and .gitignore_global live in $HOME (not .config)
  home.file = {
    ".gitconfig" = {
      source = ../../dotfiles-source/git/.gitconfig;
    };
    ".gitignore_global" = {
      source = ../../dotfiles-source/git/.gitignore_global;
    };
  };

  xdg.configFile = {
    "git/personal" = {
      source = ../../dotfiles-source/git/.config/git/personal;
    };
    "git/work" = {
      source = ../../dotfiles-source/git/.config/git/work;
    };
    "git/ignore" = {
      source = ../../dotfiles-source/git/.config/git/ignore;
    };
  };
}
