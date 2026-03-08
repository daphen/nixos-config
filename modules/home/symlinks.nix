# Symlinks for dotfiles
# Uses mkOutOfStoreSymlink so files are NOT copied to the Nix store.
# Edits to ~/dotfiles are live immediately - no rebuild needed.
{ config, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  link = config.lib.file.mkOutOfStoreSymlink;
in {
  # Files in ~/.config
  xdg.configFile = {
    "nvim".source = link "${dotfiles}/nvim/.config/nvim";
    "fish/config.fish".source = link "${dotfiles}/fish/.config/fish/config.fish";
    "fish/functions".source = link "${dotfiles}/fish/.config/fish/functions";
    "fish/conf.d".source = link "${dotfiles}/fish/.config/fish/conf.d";
    # Note: fish_variables is NOT symlinked because fish rewrites it constantly.
    # Copy it manually on new installs: cp ~/dotfiles/fish/.config/fish/fish_variables ~/.config/fish/
    "fish/fish_plugins".source = link "${dotfiles}/fish/.config/fish/fish_plugins";
    "fish/completions".source = link "${dotfiles}/fish/.config/fish/completions";
    "kitty".source = link "${dotfiles}/kitty/.config/kitty";
    "wezterm".source = link "${dotfiles}/wezterm/.config/wezterm";
    "git/personal".source = link "${dotfiles}/git/.config/git/personal";
    "git/work".source = link "${dotfiles}/git/.config/git/work";
    "git/ignore".source = link "${dotfiles}/git/.config/git/ignore";
    "mako/config".source = link "${dotfiles}/mako/.config/mako/config";
    "waybar".source = link "${dotfiles}/waybar/.config/waybar";
    "yazi".source = link "${dotfiles}/yazi/.config/yazi";
    "qutebrowser".source = link "${dotfiles}/qutebrowser/.config/qutebrowser";
    "eww".source = link "${dotfiles}/eww/.config/eww";
    "kanata".source = link "${dotfiles}/kanata/.config/kanata";
    "niri/config.kdl".source = link "${dotfiles}/niri/.config/niri/config.kdl";
    "niri/scripts".source = link "${dotfiles}/niri/.config/niri/scripts";
    "rofi".source = link "${dotfiles}/rofi/.config/rofi";
    "themes".source = link "${dotfiles}/themes/.config/themes";
  };

  # Files in $HOME (outside ~/.config)
  home.file = {
    ".gitconfig".source = link "${dotfiles}/git/.gitconfig";
    ".gitignore_global".source = link "${dotfiles}/git/.gitignore_global";
  };

  # Claude Code config lives at ~/.claude (not ~/.config)
  home.file.".claude".source = link "${dotfiles}/claude/.claude";
}
