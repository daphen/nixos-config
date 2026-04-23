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
  # 595.58.03's in-kernel VRAM-save path (NVreg_UseKernelSuspendNotifiers=1)
  # fails on this machine: nv_pmops_suspend returns -5 with "System Power
  # Management attempted without driver procfs suspend interface". Fall back to
  # the userspace nvidia-sleep.sh path until a driver release fixes it.
  hardware.nvidia.powerManagement.kernelSuspendNotifier = false;
  hardware.nvidia.prime = {
    offload.enable = true;
    offload.enableOffloadCmd = true;
    amdgpuBusId = "PCI:101:0:0";
    nvidiaBusId = "PCI:100:0:0";
  };

  # Swap file for hibernate (s2idle wake doesn't work — user always resumes from
  # hibernate after the delay timer fires. Keep delay short for quick resume.)
  swapDevices = [{ device = "/swapfile"; size = 65 * 1024; }];
  boot.resumeDevice = "/dev/disk/by-uuid/3c2ae244-45a5-4711-a8d2-aae76a3314f0";
  systemd.sleep.settings.Sleep.HibernateDelaySec = "5min";
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
  # NOTE: kbd-backlight-resume service removed — running asusctl during early
  # resume interfered with GPU initialization and caused amdgpu crashes.
  # The keyboard backlight pulse on resume remains an open issue.

  # Lid switch fires spurious "open" events during hibernate image write,
  # aborting hibernate and leaving the GPU in a crashed state. Disable lid
  # as a wake source — we wake with the power button anyway.
  systemd.services.lid-wakeup-disable = {
    description = "Disable lid switch wakeup before sleep";
    before = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "lid-wakeup-disable" ''
        [ -f /sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup ] && \
          echo disabled > /sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup
      '';
    };
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

  # MT7925 Bluetooth: SCO socket returns EOPNOTSUPP without this fix,
  # breaking HFP/HSP (no mic in video calls).
  boot.extraModprobeConfig = "options btusb force_scofix=1";

  # Unbind snd_hda_intel from the NVIDIA GPU's HDA function. snd_hda_intel
  # otherwise polls the device every ~30s to detect HDMI audio sinks, which
  # wakes the dGPU out of runtime suspend and glitches system audio (esp. BT).
  # HDMI audio from the dGPU isn't a use case on this machine.
  services.udev.extraRules = ''
    SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ACTION=="add", RUN+="${pkgs.bash}/bin/sh -c 'echo %k > /sys/bus/pci/drivers/snd_hda_intel/unbind 2>/dev/null || true'"
  '';

  # ASUS control daemon — manages keyboard lighting, fan curves, etc.
  services.asusd.enable = true;

  # TODO: MT7925 WiFi — should work on linuxPackages_latest (>=6.7)
}
