# Hardware Configuration
# =======================
# 
# This file will be auto-generated in the VM by:
# sudo nixos-generate-config --root /mnt
#
# Or if already installed:
# sudo nixos-generate-config
#
# Copy the generated hardware-configuration.nix here.
# For now, this is a placeholder.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  # Placeholder boot configuration
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Placeholder filesystem configuration
  # REPLACE THIS with your actual configuration
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-WITH-YOUR-UUID";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/REPLACE-WITH-YOUR-UUID";
    fsType = "vfat";
  };

  swapDevices = [ ];

  # Networking
  networking.useDHCP = lib.mkDefault true;

  # CPU
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
