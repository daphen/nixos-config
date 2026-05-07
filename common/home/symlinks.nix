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
    "git/personal".source = link "${dotfiles}/git/.config/git/personal";
    "git/work".source = link "${dotfiles}/git/.config/git/work";
    "git/ignore".source = link "${dotfiles}/git/.config/git/ignore";
    "mako".source = link "${dotfiles}/mako/.config/mako";
    "waybar".source = link "${dotfiles}/waybar/.config/waybar";
    "yazi".source = link "${dotfiles}/yazi/.config/yazi";
    "qutebrowser".source = link "${dotfiles}/qutebrowser/.config/qutebrowser";
    # Quickmarks: shared file format consumed by Chrome Palette via the
    # native messaging host. Edits to ~/dotfiles/quickmarks are live —
    # the host re-reads on every palette open, no rebuild needed.
    "quickmarks".source = link "${dotfiles}/quickmarks/.config/quickmarks";
    # Native messaging host manifest for Chrome Palette → quickmarks-host.
    # Helium reads ~/.config/net.imput.helium/NativeMessagingHosts/<name>.json
    # to discover hosts the extension can call via chrome.runtime.sendNativeMessage.
    "net.imput.helium/NativeMessagingHosts/com.daphen.quickmarks.json".source =
      link "${dotfiles}/quickmarks/.config/net.imput.helium/NativeMessagingHosts/com.daphen.quickmarks.json";
    "kanata".source = link "${dotfiles}/kanata/.config/kanata";
    "niri/config.kdl".source = link "${dotfiles}/niri/.config/niri/config.kdl";
    "niri/scripts".source = link "${dotfiles}/niri/.config/niri/scripts";
    "rofi".source = link "${dotfiles}/rofi/.config/rofi";
    "opencode/opencode.json".source = link "${dotfiles}/opencode/.config/opencode/opencode.json";
    "opencode/themes".source = link "${dotfiles}/opencode/.config/opencode/themes";
    "fastfetch".source = link "${dotfiles}/fastfetch/.config/fastfetch";
    "waypaper".source = link "${dotfiles}/waypaper/.config/waypaper";
    "themes".source = link "${dotfiles}/themes/.config/themes";
    "clipse/custom_theme.json".source = link "${dotfiles}/clipse/.config/clipse/custom_theme.json";
    "spotify-player/theme.toml".source = link "${dotfiles}/spotify-player/.config/spotify-player/theme.toml";
    "reference/commands-reference.md".source = link "${dotfiles}/reference/.config/commands-reference.md";
    "swaylock/config".source = link "${dotfiles}/swaylock/.config/swaylock/config";
    "starship.toml".source = link "${dotfiles}/starship/.config/starship/starship.toml";
    # Note: systemd/user services are managed by home-manager's systemd.user.services option
    # or can be manually copied to ~/.config/systemd/user/
  };

  # Files in $HOME (outside ~/.config)
  home.file = {
    ".gitconfig".source = link "${dotfiles}/git/.gitconfig";
    ".gitignore_global".source = link "${dotfiles}/git/.gitignore_global";
    "Pictures/Wallpapers".source = link "${dotfiles}/wallpapers/Pictures/Wallpapers";
    "Pictures/fastfetch".source = link "${dotfiles}/fastfetch/Pictures/fastfetch";
    # AI agent instructions — neutral file at dotfiles/ai/instructions.md
    # is the single source of truth. Claude reads it via the .claude
    # directory symlink (CLAUDE.md inside is a symlink to ai/instructions.md).
    # Codex's AGENTS.md points directly at the same neutral file here.
    ".codex/AGENTS.md".source = link "${dotfiles}/ai/instructions.md";
  };

  # Claude Code config lives at ~/.claude (not ~/.config)
  home.file.".claude".source = link "${dotfiles}/claude/.claude";
}
