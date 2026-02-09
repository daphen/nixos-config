{ config, pkgs, inputs, ... }:

{
  # Home Manager Configuration
  # ===========================

  # User information
  home.username = "daphen";
  home.homeDirectory = "/home/daphen";

  # This value determines the Home Manager release that your
  # configuration is compatible with. Don't change unnecessarily.
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # User packages (in addition to system packages)
  home.packages = with pkgs; [
    # Additional user-specific packages
    tmux
    
    # Note: Most packages are in system configuration
    # Add user-specific packages here
  ];

  # Import modular configurations
  # All dotfiles are now in ~/nixos/dotfiles/ (same repo!)
  # Edit dotfiles directly - changes take effect immediately (no rebuild needed)
  imports = [
    ./programs/git.nix
    ./programs/fish.nix
    ./programs/neovim.nix
    ./programs/terminals.nix
    ./programs/niri-scripts.nix
    ./dotfiles/theme-system.nix
    ./dotfiles/waybar.nix
    ./dotfiles/mako.nix
    ./dotfiles/misc.nix
  ];

  # Environment variables
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    BROWSER = "zen-browser";
    TERMINAL = "ghostty";
  };

  # XDG directories
  xdg.enable = true;
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = "${config.home.homeDirectory}/Desktop";
    documents = "${config.home.homeDirectory}/Documents";
    download = "${config.home.homeDirectory}/Downloads";
    music = "${config.home.homeDirectory}/Music";
    pictures = "${config.home.homeDirectory}/Pictures";
    videos = "${config.home.homeDirectory}/Videos";
    publicShare = "${config.home.homeDirectory}/Public";
    templates = "${config.home.homeDirectory}/Templates";
  };

  # Enable systemd user services
  systemd.user.startServices = "sd-switch";
}
