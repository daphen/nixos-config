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
  # NOTE: Dotfile-dependent imports commented out for initial testing
  imports = [
    ./programs/git.nix
    ./programs/fish.nix          # Re-enabled - works perfectly in QEMU!
    # ./programs/neovim.nix        # Requires dotfiles-source
    # ./programs/terminals.nix     # Requires dotfiles-source
    # ./programs/niri-scripts.nix  # Requires dotfiles-source
    # ./dotfiles/theme-system.nix  # Requires dotfiles-source
    # ./dotfiles/waybar.nix        # Requires dotfiles-source
    # ./dotfiles/mako.nix          # Requires dotfiles-source
    # ./dotfiles/misc.nix          # Requires dotfiles-source
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
