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

  # blueman intentionally NOT enabled — its applet emits duplicate
  # connect/disconnect notifications on top of the toggle-headphones
  # script. Bluetooth control lives in the QS BluetoothPicker + bluetoothctl.

  # Additional bluetooth packages
  environment.systemPackages = with pkgs; [
    bluez
    bluez-tools
  ];
}
