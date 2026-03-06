# User programs - only installation and Nix integration
# All config files are handled by symlinks.nix
{ pkgs, ... }:
{
  # Shell
  programs.fish.enable = true;
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  # Editor
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    package = pkgs.unstable.neovim-unwrapped;
    extraPackages = with pkgs; [
      nodejs
      python3
      python3Packages.pip
      nodePackages.prettier
      black
      stylua
      nodePackages.eslint
      gcc
      gnumake
      wl-clipboard
      xclip
      ripgrep
      fd
    ];
  };

  # Git
  programs.git.enable = true;
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
      editor = "nvim";
    };
  };
  programs.lazygit.enable = true;

  # Terminals
  programs.kitty.enable = true;
  programs.wezterm.enable = true;
  programs.alacritty.enable = true;

  # File manager
  programs.yazi = {
    enable = true;
    enableFishIntegration = true;
  };

  # Notifications
  services.mako.enable = true;

  # Waybar
  programs.waybar = {
    enable = true;
    systemd.enable = true;
  };
}
