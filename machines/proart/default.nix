{ config, pkgs, lib, ... }:

let
  # Finds the U2725QE's DP connector by EDID and forces amdgpu's DSC policy
  # so 4K120 fits the monitor's HBR2-capped USB4 tunnel (see the comment at
  # the udev rule below). Debounced: trigger_hotplug fires another udev
  # change event, and the runtime dsc_clock_en read breaks the loop.
  u2725qeDsc = pkgs.writeShellScriptBin "u2725qe-dsc" ''
    set -eu
    for conn in /sys/class/drm/card*-DP-*; do
      ${pkgs.gnugrep}/bin/grep -qs "U2725QE" "$conn/edid" || continue
      [ "$(cat "$conn/status")" = "connected" ] || continue
      base=$(basename "$conn")          # e.g. card2-DP-5
      card=''${base%%-*}                # card2
      name=''${base#*-}                 # DP-5
      pci=$(basename "$(readlink -f "/sys/class/drm/$card/device")")
      d="/sys/kernel/debug/dri/$pci/$name"
      [ -e "$d/dsc_clock_en" ] || continue
      # already streaming with DSC → done (breaks the hotplug event loop)
      [ "$(head -c1 "$d/dsc_clock_en")" = "1" ] && continue
      stamp=/run/u2725qe-dsc.stamp
      now=$(date +%s)
      if [ -f "$stamp" ]; then
        last=$(stat -c %Y "$stamp")
        [ $((now - last)) -lt 8 ] && continue
      fi
      touch "$stamp"
      echo 0x1 > "$d/dsc_clock_en"
      echo 1 > "$d/trigger_hotplug"
    done
  '';
in
{
  imports = [
    ../../common
    ./hardware-configuration.nix
  ];

  networking.hostName = "proart";

  # AMD OLED panel — fix PSR2 flickering + disable IPS2 dynamic
  # dcdebugmask bits: 0x200 = DC_DISABLE_PSR_SU, 0x4000 = DC_DISABLE_IPS2_DYNAMIC.
  # IPS2 dynamic entry/exit on DCN3.5 is fragile: amdgpu wedged + ring-reset on
  # 2026-05-14, then a brightness sweep (which exits IPS) hung the system hard.
  # Disabling just the IPS2 dynamic sub-state costs ~0.5W idle vs. full IPS off.
  # NVreg_DynamicPowerManagement=0x02 enables fine-grained PM so NVIDIA stays suspended
  boot.kernelParams = [
    "amdgpu.dcdebugmask=0x4200"
    "amdgpu.sg_display=0" # fix DCN3.5 idle power opt stalls (video freeze + audio static)
    "amdgpu.abmlevel=0" # disable adaptive backlight modulation — caps OLED at ~76% with content-driven dimming
    "resume=/dev/disk/by-uuid/3c2ae244-45a5-4711-a8d2-aae76a3314f0"
    "resume_offset=18552832"
    # NOTE: do NOT set hibernate.compressor=lz4 — the nixpkgs kernel is built
    # without CONFIG_HIBERNATION_COMP_LZ4; with it set, every image write
    # failed silently (resume: "Image not found", dirty fs, fsck at boot).
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
  # The module wires nvidia-suspend into systemd-hibernate too, so BOTH
  # nvidia-suspend and nvidia-hibernate race the single writer at
  # /proc/driver/nvidia/suspend on every hibernate — one hook gets EIO and
  # GSP state ends up half-saved, which is exactly the dead-heartbeat /
  # never-reactivated-session black screen on resume (journal 2026-07-25
  # 23:56:24 → 2026-07-26 12:42:30). Hibernate is nvidia-hibernate's alone;
  # suspend-then-hibernate runs the suspend hook at its suspend phase.
  systemd.services.nvidia-suspend.wantedBy = lib.mkForce [
    "systemd-suspend.service"
    "systemd-suspend-then-hibernate.service"
  ];
  hardware.nvidia.prime = {
    offload.enable = true;
    offload.enableOffloadCmd = true;
    amdgpuBusId = "PCI:101:0:0";
    nvidiaBusId = "PCI:100:0:0";
  };

  # Swap file for hibernate. Sized > RAM (61G) + dGPU VRAM (16G):
  # PreserveVideoMemoryAllocations copies VRAM into RAM before the image is
  # written, so a 65G file couldn't hold a heavy session's image →
  # NV_ERR_NO_MEMORY, corrupt image, failed resume.
  swapDevices = [{ device = "/swapfile"; size = 80 * 1024; }];
  boot.resumeDevice = "/dev/disk/by-uuid/3c2ae244-45a5-4711-a8d2-aae76a3314f0";
  # Lid = hibernate IMMEDIATELY. s2idle wake has never worked on this machine
  # (every logged suspend exit is the hibernate timer; lid-opens during the old
  # suspend-then-hibernate window froze the system), so the suspend leg was
  # pure hazard. Cost: image write on every close and disk-resume on every open.
  services.logind.settings.Login.HandleLidSwitch = "hibernate";
  # Cap the hibernate image: kernel drops page cache instead of writing it.
  # Full-RAM images (40G+ with dev stacks up) made writes multi-minute and one
  # quick-turnaround restore hung at a black screen (2026-07-25). 8G images
  # write and restore in well under a minute; cost is cold caches after resume.
  systemd.tmpfiles.rules = [ "w /sys/power/image_size - - - - 8589934592" ];

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
  # After S4 resume the ITE 8910 keyboard-backlight controller (USB 0b05:19b6)
  # comes back stuck in its firmware "breathe" animation AND deaf to brightness
  # control — the Fn backlight key and asusd are both ignored (asusd reports
  # "off" but the WMI/Aura path doesn't govern the controller in this state). A
  # cold boot fixes it because it re-enumerates the USB device; hibernate doesn't.
  # The fix: deauthorize+reauthorize the USB device, which re-inits it exactly
  # like a cold boot (verified 2026-06-23 — pulse stops, Fn key returns).
  #
  # Must NOT run inline during early resume: a prior asusctl-on-resume attempt
  # raced amdgpu init and crashed the GPU. So the resume unit only *schedules* a
  # detached one-shot ~12s later, well after the GPU is back. Decoupled from the
  # sleep transition: it can neither block nor loop hibernate. Match the device
  # by vendor/product, not the 3-4 bus path, which can shift across boots.
  systemd.services.kbd-backlight-resume = {
    description = "Re-init ASUS keyboard backlight controller after resume";
    after = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    wantedBy = [ "systemd-suspend.service" "systemd-suspend-then-hibernate.service" "systemd-hibernate.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemd-run --on-active=12 --timer-property=AccuracySec=1s ${pkgs.writeShellScript "kbd-backlight-reinit" ''
        for dev in /sys/bus/usb/devices/*; do
          [ -e "$dev/idVendor" ] || continue
          if [ "$(${pkgs.coreutils}/bin/cat "$dev/idVendor")" = "0b05" ] && \
             [ "$(${pkgs.coreutils}/bin/cat "$dev/idProduct")" = "19b6" ]; then
            echo 0 > "$dev/authorized"
            ${pkgs.coreutils}/bin/sleep 1
            echo 1 > "$dev/authorized"
            break
          fi
        done
        ${pkgs.coreutils}/bin/sleep 2
        ${pkgs.asusctl}/bin/asusctl leds set off || true
      ''}";
    };
  };

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
        for w in /sys/devices/platform/PNP0C0D:*/power/wakeup \
                 /sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:*/power/wakeup; do
          [ -f "$w" ] && echo disabled > "$w"
        done
        exit 0
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
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="676d", TAG+="uaccess", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="676d", TAG+="uaccess", MODE="0666"
    ACTION=="add|change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="${u2725qeDsc}/bin/u2725qe-dsc"
  '';

  # Dell U2725QE over the single TB4 cable: the monitor's USB4 DP tunnel
  # caps at HBR2 (its firmware skips BW-allocation mode with AMD hosts) and
  # amdgpu never tries DSC on DPIA links by itself, so the kernel prunes
  # 4K@120. Forcing the connector's DSC policy makes the mode validate —
  # 4K120 compressed fits HBR2 easily and the panel decodes DSC natively.
  # The udev rule above re-applies it on every connect; niri then picks up
  # the 120Hz mode from its output config. dsc_clock_en reads back the
  # RUNTIME state (1 once the 120Hz stream runs), which both makes the
  # script idempotent and terminates the udev change-event loop that the
  # trigger_hotplug itself causes.
  environment.systemPackages = [ u2725qeDsc ];

  # ASUS control daemon — manages keyboard lighting, fan curves, etc.
  services.asusd.enable = true;

  # Local embeddings for the notes vault semantic search. CPU is plenty
  # for nomic-embed-text (137M params, ~30ms/embed). Exposed to the
  # webapp via `tailscale funnel` so Vercel can reach it at
  # https://<host>.<tailnet>.ts.net for /api/search and /api/sync.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cpu;
    loadModels = [ "nomic-embed-text" ];
  };

  # TODO: MT7925 WiFi — should work on linuxPackages_latest (>=6.7)
}
