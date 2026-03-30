{ config, pkgs, ... }:

{
  # Bluetooth Configuration
  # ========================
  
  # Enable bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true;
      };
    };
  };

  # Bluetooth manager
  services.blueman.enable = true;

  # Additional bluetooth packages
  environment.systemPackages = with pkgs; [
    bluez
    bluez-tools
  ];
}
