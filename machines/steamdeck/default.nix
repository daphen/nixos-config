{ config, lib, pkgs, inputs, ... }:

let
  canvas = inputs.hyprland-canvas.packages.${pkgs.system}.default;

  deckInputPlumber = pkgs.inputplumber;

  inputProfile = pkgs.writeText "hyprland-canvas-input.yaml" ''
    # yaml-language-server: $schema=https://raw.githubusercontent.com/ShadowBlip/InputPlumber/v0.78.0/rootfs/usr/share/inputplumber/schema/device_profile_v1.json
    version: 1
    kind: DeviceProfile
    name: Hyprland Canvas
    description: Steam Deck controls for David's Hyprland canvas
    target_devices:
      - keyboard
      - mouse
    mapping:
      - name: Steam button
        source_event: { gamepad: { button: Guide } }
        target_events: [ { keyboard: KeyF23 } ]
      - name: D-pad left
        source_event: { gamepad: { button: DPadLeft } }
        target_events: [ { keyboard: KeyF13 } ]
      - name: D-pad down
        source_event: { gamepad: { button: DPadDown } }
        target_events: [ { keyboard: KeyF14 } ]
      - name: D-pad up
        source_event: { gamepad: { button: DPadUp } }
        target_events: [ { keyboard: KeyF15 } ]
      - name: D-pad right
        source_event: { gamepad: { button: DPadRight } }
        target_events: [ { keyboard: KeyF16 } ]
      - name: Move modifier
        source_event: { gamepad: { button: LeftPaddle1 } }
        target_events: [ { keyboard: KeyLeftShift } ]
      - name: Resize modifier
        source_event: { gamepad: { button: RightPaddle1 } }
        target_events: [ { keyboard: KeyLeftCtrl } ]
      - name: Left pad pan left
        source_event: { touchpad: { name: LeftPad, touch: { motion: { region: left } } } }
        target_events: [ { keyboard: KeyF17 } ]
      - name: Left pad pan down
        source_event: { touchpad: { name: LeftPad, touch: { motion: { region: bottom } } } }
        target_events: [ { keyboard: KeyF18 } ]
      - name: Left pad pan up
        source_event: { touchpad: { name: LeftPad, touch: { motion: { region: top } } } }
        target_events: [ { keyboard: KeyF19 } ]
      - name: Left pad pan right
        source_event: { touchpad: { name: LeftPad, touch: { motion: { region: right } } } }
        target_events: [ { keyboard: KeyF20 } ]
      - name: Right pad pointer
        source_event: { touchpad: { name: RightPad, touch: { motion: {} } } }
        target_events: [ { mouse: { motion: { speed_pps: 800 } } } ]
      - name: Right pad click
        source_event: { touchpad: { name: RightPad, touch: { button: Press } } }
        target_events: [ { mouse: { button: Left } } ]
      - name: Activate
        source_event: { gamepad: { button: South } }
        target_events: [ { keyboard: KeyEnter } ]
      - name: Escape
        source_event: { gamepad: { button: East } }
        target_events: [ { keyboard: KeyEsc } ]
      - name: Overview
        source_event: { gamepad: { button: North } }
        target_events: [ { keyboard: KeyF21 } ]
      - name: On-screen keyboard
        source_event: { gamepad: { button: West } }
        target_events: [ { keyboard: KeyF22 } ]
  '';
  gamingInputProfile = pkgs.writeText "hyprland-gaming-input.yaml" ''
    version: 1
    kind: DeviceProfile
    name: Hyprland Gaming
    description: Steam gamepad controls with native Hyprland Guide tap and hold
    target_devices: [ deck-uhid, keyboard ]
    mapping:
      - name: Steam button
        source_event: { gamepad: { button: Guide } }
        target_events: [ { keyboard: KeyF23 } ]
  '';
  releaseInput = pkgs.writeShellScriptBin "deck-input-release" ''
    if ${deckInputPlumber}/bin/inputplumber device 0 info >/dev/null 2>&1; then
      ${deckInputPlumber}/bin/inputplumber device 0 profile load \
        ${deckInputPlumber}/share/inputplumber/profiles/default.yaml || true
    fi
    ${deckInputPlumber}/bin/inputplumber devices manage-all || true
  ''; 
  startCanvas = pkgs.writeShellScriptBin "start-hyprland-canvas" ''
    release() { ${releaseInput}/bin/deck-input-release; }
    trap release EXIT INT TERM
    ${deckInputPlumber}/bin/inputplumber devices manage-all --enable
    for attempt in $(${pkgs.coreutils}/bin/seq 1 30); do
      if ${deckInputPlumber}/bin/inputplumber device 0 info >/dev/null 2>&1; then
        ${deckInputPlumber}/bin/inputplumber device 0 profile load \
          /etc/inputplumber/profiles/hyprland-canvas.yaml
        break
      fi
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    export HYPR_CANVAS_REAL=1
    export HYPR_CANVAS_CAMERA=1
    export HYPR_CANVAS_PROFILE=deck
    export HYPR_SCRIPTS="$HOME/.config/hypr/scripts/"
    ${canvas}/bin/start-hyprland -- --config "$HOME/.config/hypr/hyprland.lua"
  '';
  gamingMode = pkgs.writeShellApplication {
    name = "deck-gaming-mode";
    runtimeInputs = [ canvas deckInputPlumber pkgs.jq pkgs.systemd pkgs.util-linux ];
    text = builtins.readFile ../../dotfiles/hyprland/.config/hypr/scripts/deck-gaming-mode;
  };
  osk = pkgs.writeShellScriptBin "deck-osk-toggle" ''
    if ${pkgs.procps}/bin/pgrep -x wvkbd-mobintl >/dev/null; then
      exec ${pkgs.procps}/bin/pkill -x wvkbd-mobintl
    fi
    exec ${pkgs.wvkbd}/bin/wvkbd-mobintl -L 300
  '';
  canvasSession = pkgs.runCommand "hyprland-canvas-session" {
    passthru.providedSessions = [ "hyprland-canvas" ];
  } ''
    mkdir -p $out/share/wayland-sessions
    cat > $out/share/wayland-sessions/hyprland-canvas.desktop <<EOF
    [Desktop Entry]
    Name=Hyprland Canvas
    Comment=Steam Deck desktop canvas
    Exec=${startCanvas}/bin/start-hyprland-canvas
    Type=Application
    DesktopNames=Hyprland
    EOF
  '';
  gamingModeEntry = pkgs.makeDesktopItem {
    name = "gaming-mode";
    desktopName = "Gaming Mode";
    comment = "Open Steam Big Picture without ending the work session";
    exec = "${gamingMode}/bin/deck-gaming-mode";
    icon = "steam";
    categories = [ "Game" ];
  };
  oskEntry = pkgs.makeDesktopItem {
    name = "on-screen-keyboard";
    desktopName = "On-screen Keyboard";
    exec = "${osk}/bin/deck-osk-toggle";
    icon = "input-keyboard";
    categories = [ "Utility" ];
  };
in
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "steamdeck";
  networking.networkmanager.enable = true;
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelModules = [ "uhid" ];
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  users.users.daphen = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" "video" "audio" "input" ];
    shell = pkgs.fish;
  };
  programs.fish.enable = true;
  security.sudo.wheelNeedsPassword = false;
  security.polkit.enable = true;
  security.rtkit.enable = true;
  security.pam.services.swaylock = {};

  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.dbus.enable = true;
  services.openssh.enable = true;
  services.upower.enable = true;
  services.fwupd.enable = true;
  services.getty.autologinUser = null;
  systemd.services."getty@tty2".enable = true;

  jovian.devices.steamdeck = {
    enable = true;
    autoUpdate = false;
  };
  services.inputplumber.package = deckInputPlumber;
  jovian.steam = {
    enable = true;
    autoStart = true;
    user = "daphen";
    desktopSession = "hyprland-canvas";
  };
  services.displayManager = {
    defaultSession = lib.mkForce "hyprland-canvas";
    sessionPackages = [ canvasSession ];
  };

  programs.xwayland.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-hyprland ];
    config.hyprland.default = [ "hyprland" "gtk" ];
  };

  environment.etc."inputplumber/profiles/hyprland-canvas.yaml".source = inputProfile;
  environment.etc."inputplumber/profiles/hyprland-gaming.yaml".source = gamingInputProfile;
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };
  environment.systemPackages = with pkgs; [
    canvas
    canvasSession
    gamingMode
    gamingModeEntry
    osk
    oskEntry
    deckInputPlumber
    wvkbd
    wev
    fish
    git
    vim
    kitty
    chromium
    quickshell
    swaylock-effects
    swayidle
    brightnessctl
    playerctl
    wireplumber
    networkmanager
    bluez
    libnotify
    wl-clipboard
    wl-clip-persist
    jq
    grim
    slurp
  ];

  nix = {
    settings.experimental-features = [ "nix-command" "flakes" ];
    gc.automatic = false;
  };
  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "24.11";
}
