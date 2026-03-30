{ config, pkgs, ... }:

{
  imports = [
    ../../common
    ./hardware-configuration.nix
  ];

  networking.hostName = "proart";

  # AMD OLED panel — fix PSR2 flickering
  boot.kernelParams = [ "amdgpu.dcdebugmask=0x200" ];

  # NVIDIA RTX 5080 (open = true required for RTX 50 series)
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia.open = true;
  hardware.nvidia.prime.offload.enable = true;

  # TODO: MT7925 WiFi — should work on linuxPackages_latest (>=6.7)
}
