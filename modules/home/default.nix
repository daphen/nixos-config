# Home Manager Configuration
{ config, pkgs, ... }:
{
  home.username = "daphen";
  home.homeDirectory = "/home/daphen";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  imports = [
    ./symlinks.nix
    ./programs.nix
    ./theme-system.nix
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    BROWSER = "zen-browser";
    TERMINAL = "kitty";
  };

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

  systemd.user.startServices = "sd-switch";
}
