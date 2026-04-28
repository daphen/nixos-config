{ config, pkgs, ... }:

{
  # Network Configuration
  # =====================
  
  # Enable NetworkManager
  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
  };

  # Enable IWD (iNet Wireless Daemon) as backend for NetworkManager
  networking.wireless.iwd.enable = true;
  networking.networkmanager.wifi.backend = "iwd";

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
  };

  # Prefer IPv4 over IPv6 in DNS resolution
  # IPv6 connections to some services (e.g. Spotify dealer) time out
  environment.etc."gai.conf".text = ''
    precedence ::ffff:0:0/96 100
  '';

  # DNS
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "false";
  };

  # GoLinks - maps "go" hostname to GoLinks' server so http://go/* works in all browsers
  networking.hosts = {
    "52.72.13.96" = [ "go" ];
  };

  # Disable IPv6 entirely at the kernel level.
  # The previous per-interface sysctl approach
  # (boot.kernel.sysctl."net.ipv6.conf.wlan0.disable_ipv6" = 1) was unreliable
  # because NetworkManager/iwd brings wlan0 up *after* the sysctl activation
  # script runs, and disable_ipv6 only takes effect when set before the
  # interface comes up. Result: wlan0 ended up with a link-local IPv6 address,
  # Go's HTTP client tried IPv6 first per Happy Eyeballs, and connections to
  # external services (Confidence/Spotify CDN, gcloud auth, etc.) hit
  # 30s timeouts before any IPv4 fallback. ipv6.disable=1 is unconditional —
  # it prevents the IPv6 stack from initializing at all, before any interface
  # touches it. Requires a reboot to take effect.
  boot.kernelParams = [ "ipv6.disable=1" ];

  # Additional network tools
  # NetworkManager is already included by enabling the service
  # environment.systemPackages = with pkgs; [
  #   # networkmanager-dmenu  # TODO: Find correct package name
  # ];
}
