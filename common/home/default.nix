# Home Manager Configuration
{ config, lib, pkgs, inputs, desktopProfile ? "workstation", ... }:
let
  gsettingsSchemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
  isDeck = desktopProfile == "deck";
  desktopScripts = "${config.home.homeDirectory}/.config/${if isDeck then "hypr" else "niri"}/scripts";
in
{
  home.username = "daphen";
  home.homeDirectory = "/home/daphen";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  imports = [
    ./theme-system.nix
    inputs.worktrunk.homeModules.default
  ] ++ lib.optionals (!isDeck) [
    ./symlinks.nix
    ./programs.nix
    ./daemons.nix
    ./niri-scripts.nix
  ];

  xdg.configFile = lib.mkIf isDeck (let
    dotfiles = "${config.home.homeDirectory}/nixos/dotfiles";
    link = config.lib.file.mkOutOfStoreSymlink;
  in {
    "fish/config.fish".source = link "${dotfiles}/fish/.config/fish/config.fish";
    "fish/functions".source = link "${dotfiles}/fish/.config/fish/functions";
    "fish/conf.d".source = link "${dotfiles}/fish/.config/fish/conf.d";
    "fish/fish_plugins".source = link "${dotfiles}/fish/.config/fish/fish_plugins";
    "fish/completions".source = link "${dotfiles}/fish/.config/fish/completions";
    "kitty".source = link "${dotfiles}/kitty/.config/kitty";
    "git/personal".source = link "${dotfiles}/git/.config/git/personal";
    "git/work".source = link "${dotfiles}/git/.config/git/work";
    "git/ignore".source = link "${dotfiles}/git/.config/git/ignore";
    "hypr/hyprland.lua".source = link "${dotfiles}/hyprland/.config/hypr/hyprland.lua";
    "hypr/scripts".source = link "${dotfiles}/hyprland/.config/hypr/scripts";
    "quickshell".source = link "${dotfiles}/quickshell/.config/quickshell";
    "themes".source = link "${dotfiles}/themes/.config/themes";
    "starship.toml".source = link "${dotfiles}/starship/.config/starship/starship.toml";
  });

  home.file = lib.mkIf isDeck (let
    dotfiles = "${config.home.homeDirectory}/nixos/dotfiles";
    link = config.lib.file.mkOutOfStoreSymlink;
  in {
    ".gitconfig".source = link "${dotfiles}/git/.gitconfig";
    ".gitignore_global".source = link "${dotfiles}/git/.gitignore_global";
    ".local/share/qml/QsLib".source = link "${dotfiles}/qslib/.local/share/qml/QsLib";
  });

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    BROWSER = if isDeck then "${desktopScripts}/browser-dispatch" else "browser-dispatch";
    TERMINAL = "kitty";
    # Lets glib find the gnome-desktop schema so xdg-desktop-portal-gtk
    # can read color-scheme; Chromium's "Device" mode reads from there.
    GSETTINGS_SCHEMA_DIR = gsettingsSchemaDir;
    # File-based fzf opts so theme toggles take effect immediately in
    # already-running processes (yazi, nvim, claude TUI). theme-manager
    # repoints this symlink between light/dark on toggle.
    FZF_DEFAULT_OPTS_FILE = "${config.home.homeDirectory}/.config/fzf/opts.conf";
    # QsLib shared QML module (dotfiles/qslib) for quickshell apps + bar.
    QML2_IMPORT_PATH = "${config.home.homeDirectory}/.local/share/qml";
    # Route GTK/Chromium file dialogs through the portal, where
    # termfilechooser serves them as yazi-in-kitty.
    GTK_USE_PORTAL = "1";
  };

  systemd.user.sessionVariables = {
    GSETTINGS_SCHEMA_DIR = gsettingsSchemaDir;
    QML2_IMPORT_PATH = "${config.home.homeDirectory}/.local/share/qml";
  };

  xdg.enable = true;
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    # Default changed at HM 26.05 (true → false). Pin to true so XDG_*_DIR
    # env vars stay exported for apps that read them out of the session
    # environment instead of ~/.config/user-dirs.dirs directly.
    setSessionVariables = true;
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
    exec = "${desktopScripts}/chromium-launch %U";
    icon = "google-chrome";
    terminal = false;
    type = "Application";
    categories = [ "Network" "WebBrowser" ];
    mimeType = [ "application/pdf" "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
    settings.StartupWMClass = "google-chrome";
  };

  xdg.desktopEntries.browser-dispatch = {
    name = "Browser Dispatch";
    comment = "Routes URLs to the correct browser profile (personal or work)";
    exec = "${desktopScripts}/browser-dispatch %u";
    terminal = false;
    type = "Application";
    categories = [ "Network" "WebBrowser" ];
    mimeType = [ "x-scheme-handler/http" "x-scheme-handler/https" "text/html" "x-scheme-handler/spotify" ];
    noDisplay = true;
  };

  xdg.desktopEntries.restart-wifi = {
    name = "Restart Wi-Fi";
    comment = "Deactivate and reconnect the active Wi-Fi connection";
    exec = "${desktopScripts}/restart-wifi";
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
      "x-scheme-handler/spotify" = "browser-dispatch.desktop";
    };
  };

  systemd.user.startServices = "sd-switch";
}
