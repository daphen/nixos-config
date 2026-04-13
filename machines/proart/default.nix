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
    "amdgpu.sg_display=0" # fix DCN3.5 idle power opt stalls (video freeze + audio static)
    "resume=/dev/disk/by-uuid/3c2ae244-45a5-4711-a8d2-aae76a3314f0"
    "resume_offset=421093376"
    "nvidia.NVreg_DynamicPowerManagement=0x02"
    # Prevent ACPI EC from waking the system during s2idle.
    "acpi.ec_no_wakeup=1"
    # pinctrl_amd GPIO controller (IRQ 7) fires spurious wakeup events during
    # s2idle (pm_wakeup_irq=7). All S0i3-wake-enabled pins on AMDI0030:00 are
    # ignored — lid (LID0) and power button (PWRB) use dedicated ACPI wakeup
    # paths and are unaffected.
    "gpiolib_acpi.ignore_wake=AMDI0030:00@0,AMDI0030:00@5,AMDI0030:00@16,AMDI0030:00@54,AMDI0030:00@58,AMDI0030:00@59"
    # Mask gpe1A — low-frequency GPE (~10 events/boot) that triggers an ACPI
    # D-Notifier to the NVIDIA GPU during s2idle entry. The NVIDIA driver times
    # out handling it (status=0x11), calls pm_wakeup_event(), and the system
    # resumes within milliseconds of entering s2idle.
    "acpi_mask_gpe=0x1a"
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

  # MT7925 combo chip (WiFi+BT) generates wake events during s2idle causing a
  # suspend loop. rfkill block/unblock both radios around sleep to prevent this.
  systemd.services.bluetooth-sleep = {
    description = "Block Bluetooth and WiFi before suspend";
    before = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.util-linux}/bin/rfkill block all"; };
  };
  systemd.services.bluetooth-resume = {
    description = "Unblock Bluetooth and WiFi after resume";
    after = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.util-linux}/bin/rfkill unblock all"; };
  };

  # XHC (USB host) controllers fire PME wakeup events during s2idle causing a
  # suspend loop — the USB-C port's UCSI_GET_PDOS errors are the likely trigger.
  # Charging goes through UCSI/EC and is unaffected by disabling XHC wakeup.
  systemd.services.usb-wakeup-disable = {
    description = "Disable USB controller wakeup before suspend";
    before = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "usb-wakeup-disable" ''
        for dev in \
          /sys/bus/pci/devices/0000:64:00.0 \
          /sys/bus/pci/devices/0000:65:00.4 \
          /sys/bus/pci/devices/0000:67:00.0 \
          /sys/bus/pci/devices/0000:67:00.3 \
          /sys/bus/pci/devices/0000:67:00.4 \
          /sys/bus/pci/devices/0000:67:00.5; do
          [ -f "$dev/power/wakeup" ] && echo disabled > "$dev/power/wakeup"
        done
      '';
    };
  };

  # ASUS control daemon — manages keyboard lighting, fan curves, etc.
  services.asusd.enable = true;

  # TODO: MT7925 WiFi — should work on linuxPackages_latest (>=6.7)
}
