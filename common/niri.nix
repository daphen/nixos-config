{ config, pkgs, inputs, ... }:

{
  # Niri Window Manager Configuration
  # ==================================
  # Uses niri-unstable from niri-flake — tracks niri's master branch.
  # "unstable" is a misnomer; tagged releases (v26.04 etc.) are cut from
  # this branch, and niri-flake updates the lock multiple times per day.
  # niri-stable in niri-flake currently lags and is hardcoded to expect
  # the pre-v26.04 systemd service file format.
  # The niri-flake nixosModule is imported in flake.nix and provides
  # programs.niri options, dbus config, polkit, portals, etc.

  programs.niri.enable = true;
  programs.niri.package = inputs.niri-flake.packages.x86_64-linux.niri-unstable;

  # Use console autologin instead
  services.getty.autologinUser = "daphen";

  # Wayland session management
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";  # Enable Wayland for Electron apps
    MOZ_ENABLE_WAYLAND = "1";  # Enable Wayland for Firefox
    QT_QPA_PLATFORMTHEME = "kvantum";  # Use Kvantum for Qt theming
    QT_STYLE_OVERRIDE = "kvantum";  # Force Kvantum style
  };

  # XWayland support
  programs.xwayland.enable = true;

  # Additional Wayland tools
  environment.systemPackages = with pkgs; [
    xwayland-satellite  # For X11 app positioning
    waybar              # Status bar
  ];
}
