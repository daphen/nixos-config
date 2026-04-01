{ config, pkgs, ... }:

{
  imports = [
    ../../common
    ./hardware-configuration.nix
  ];

  networking.hostName = "proart";

  # AMD OLED panel — fix PSR2 flickering
  # NVreg_DynamicPowerManagement=0x02 enables fine-grained PM so NVIDIA stays suspended
  boot.kernelParams = [
    "amdgpu.dcdebugmask=0x200"
    "resume_offset=421093376"
    "nvidia.NVreg_DynamicPowerManagement=0x02"
  ];

  # NVIDIA RTX 5080 (open = true required for RTX 50 series)
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia.open = true;
  hardware.nvidia.powerManagement.enable = true;
  hardware.nvidia.powerManagement.finegrained = true;
  hardware.nvidia.prime = {
    offload.enable = true;
    offload.enableOffloadCmd = true;
    amdgpuBusId = "PCI:101:0:0";
    nvidiaBusId = "PCI:100:0:0";
  };

  # Swap file for hibernate (s2idle is the only sleep mode on this machine,
  # which keeps CPU warm — suspend-then-hibernate powers off fully after 30min)
  swapDevices = [{ device = "/swapfile"; size = 65 * 1024; }];
  boot.resumeDevice = "/dev/disk/by-uuid/3c2ae244-45a5-4711-a8d2-aae76a3314f0";
  systemd.sleep.settings.Sleep.HibernateDelaySec = "30min";
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

  # nvidia-suspend.service only declares Before=systemd-suspend.service by default,
  # but lid uses suspend-then-hibernate — pull it into all sleep paths explicitly.
  systemd.services.nvidia-suspend.wantedBy = [
    "systemd-suspend-then-hibernate.service"
    "systemd-hibernate.service"
  ];
  systemd.services.nvidia-resume.wantedBy = [
    "systemd-suspend-then-hibernate.service"
    "systemd-hibernate.service"
  ];
  systemd.services.nvidia-resume.unitConfig.After = [
    "systemd-suspend-then-hibernate.service"
    "systemd-hibernate.service"
  ];

  # MT7925 Bluetooth generates wake events during s2idle causing a suspend loop.
  # rfkill block/unblock around sleep to prevent this.
  systemd.services.bluetooth-sleep = {
    description = "Block Bluetooth before suspend";
    before = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.util-linux}/bin/rfkill block bluetooth"; };
  };
  systemd.services.bluetooth-resume = {
    description = "Unblock Bluetooth after resume";
    after = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.util-linux}/bin/rfkill unblock bluetooth"; };
  };

  # ASUS control daemon — manages keyboard lighting, fan curves, etc.
  services.asusd.enable = true;

  # TODO: MT7925 WiFi — should work on linuxPackages_latest (>=6.7)
}
