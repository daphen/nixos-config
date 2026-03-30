{ config, pkgs, ... }:

{
  imports = [
    ../../common
    ./hardware-configuration.nix
  ];

  networking.hostName = "thinkpad";

  # Intel Lunar Lake GPU
  boot.kernelParams = [ "i915.enable_psr=0" "i915.enable_dc=0" "i915.enable_guc=0" ];
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
  ];
}
