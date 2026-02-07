{ config, pkgs, ... }:

{
  # Niri Window Manager Configuration
  # ==================================
  
  programs.niri = {
    enable = true;
    package = pkgs.unstable.niri;
  };

  # Disable greetd - causes VM freezes
  # TODO: Re-enable once VM graphics issues are resolved
  # services.greetd = {
  #   enable = true;
  #   settings = {
  #     default_session = {
  #       command = "${pkgs.greetd.tuigreet}/bin/tuigreet --cmd niri-session";
  #       user = "greeter";
  #     };
  #   };
  # };
  
  # Use console autologin instead
  services.getty.autologinUser = "daphen";

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
