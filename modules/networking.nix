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

  # DNS
  services.resolved = {
    enable = true;
    dnssec = "allow-downgrade";
  };

  # Additional network tools
  environment.systemPackages = with pkgs; [
    networkmanager
    networkmanager-dmenu  # Dmenu for NetworkManager
  ];
}
