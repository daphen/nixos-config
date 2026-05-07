# Home Manager Configuration
{ config, pkgs, inputs, ... }:
{
  home.username = "daphen";
  home.homeDirectory = "/home/daphen";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  imports = [
    ./symlinks.nix
    ./programs.nix
    ./theme-system.nix
    inputs.worktrunk.homeModules.default
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    BROWSER = "browser-dispatch";
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

  xdg.desktopEntries.google-chrome = {
    name = "Google Chrome";
    comment = "Access the Internet";
    exec = "${config.home.homeDirectory}/.config/niri/scripts/chromium-launch %U";
    icon = "google-chrome";
    terminal = false;
    type = "Application";
    categories = [ "Network" "WebBrowser" ];
    mimeType = [ "application/pdf" "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
    settings.StartupWMClass = "google-chrome";
  };

  xdg.desktopEntries.browser-dispatch = {
    name = "Browser Dispatch";
    comment = "Routes URLs to the correct Vivaldi profile (personal or work)";
    exec = "${config.home.homeDirectory}/.config/niri/scripts/browser-dispatch %u";
    terminal = false;
    type = "Application";
    categories = [ "Network" "WebBrowser" ];
    mimeType = [ "x-scheme-handler/http" "x-scheme-handler/https" "text/html" ];
    noDisplay = true;
  };

  xdg.desktopEntries.restart-wifi = {
    name = "Restart Wi-Fi";
    comment = "Deactivate and reconnect the active Wi-Fi connection";
    exec = "${config.home.homeDirectory}/.config/niri/scripts/restart-wifi";
    icon = "network-wireless";
    terminal = false;
    type = "Application";
    categories = [ "Network" "System" ];
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "x-scheme-handler/http" = "browser-dispatch.desktop";
      "x-scheme-handler/https" = "browser-dispatch.desktop";
      "text/html" = "browser-dispatch.desktop";
    };
  };

  systemd.user.startServices = "sd-switch";
}
