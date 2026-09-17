{ lib, ... }:

{
  # These labels name only the new NixOS partitions; arrival-day inspection must reconcile them before installation.
  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_DECK_ROOT";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_DECK_EFI";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
  swapDevices = [];
}
