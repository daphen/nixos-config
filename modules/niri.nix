{ config, pkgs, ... }:

{
  # Niri Window Manager Configuration
  # ==================================
  
  programs.niri = {
    enable = true;
    package = pkgs.unstable.niri;
  };

  # Enable required services for Niri
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --cmd niri-session";
        user = "greeter";
      };
    };
  };

  # Wayland session management
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";  # Enable Wayland for Electron apps
    MOZ_ENABLE_WAYLAND = "1";  # Enable Wayland for Firefox
  };

  # XWayland support
  programs.xwayland.enable = true;

  # Additional Wayland tools
  environment.systemPackages = with pkgs; [
    xwayland-satellite  # For X11 app positioning
    waybar              # Status bar
  ];
}
