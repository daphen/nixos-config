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

  boot.kernel.sysctl = {
    "net.ipv6.conf.wlan0.disable_ipv6" = 1;                                                                                                       
  };                                                                                                                                              

  # Additional network tools
  # NetworkManager is already included by enabling the service
  # environment.systemPackages = with pkgs; [
  #   # networkmanager-dmenu  # TODO: Find correct package name
  # ];
}
