{ config, pkgs, ... }:

{
  imports = [
    ../../common
    # ./hardware-configuration.nix  # TODO: generate after install
  ];

  networking.hostName = "zenbook";

  # TODO: AMD HX 370 (AMD-only, no dGPU)
  # TODO: MT7925 WiFi — may need kernel >=6.7 or firmware blob
}
