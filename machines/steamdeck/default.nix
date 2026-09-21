{ config, lib, pkgs, inputs, ... }:

let
  canvas = inputs.hyprland-canvas.packages.${pkgs.system}.default.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./hyprland-deck.patch ];
  });

  deckInputPlumber = pkgs.inputplumber.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./inputplumber-native-gestures.patch
      ./inputplumber-pad-force.patch
    ];
    nativeCheckInputs = (old.nativeCheckInputs or []) ++ [ (lib.getBin pkgs.dbus) ];
    preCheck = (old.preCheck or "") + ''
      readarray -t dbus_info < <(dbus-daemon --config-file=${lib.getBin pkgs.dbus}/share/dbus-1/session.conf --address=unix:tmpdir="$TMPDIR" --fork --print-address=1 --print-pid=1)
      export DBUS_SESSION_BUS_ADDRESS="''${dbus_info[0]}"
      export DBUS_SESSION_BUS_PID="''${dbus_info[1]}"
      trap 'kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true' EXIT
    '';
  });

  inputProfile = pkgs.writeText "hyprland-canvas-input.yaml" ''
    # yaml-language-server: $schema=https://raw.githubusercontent.com/ShadowBlip/InputPlumber/v0.78.0/rootfs/usr/share/inputplumber/schema/device_profile_v1.json
    version: 1
    kind: DeviceProfile
    name: Hyprland Canvas
    description: Steam Deck controls for David's Hyprland canvas
    target_devices:
      - deck-uhid
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
      - name: Left stick up
        source_event: { gamepad: { axis: { name: LeftStick, direction: up, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF15 } ]
      - name: Left stick down
        source_event: { gamepad: { axis: { name: LeftStick, direction: down, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF14 } ]
      - name: Left stick left
        source_event: { gamepad: { axis: { name: LeftStick, direction: left, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF13 } ]
      - name: Left stick right
        source_event: { gamepad: { axis: { name: LeftStick, direction: right, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF16 } ]
      - name: Right stick left
        source_event: { gamepad: { axis: { name: RightStick, direction: left, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF1 } ]
      - name: Right stick down
        source_event: { gamepad: { axis: { name: RightStick, direction: down, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF2 } ]
      - name: Right stick up
        source_event: { gamepad: { axis: { name: RightStick, direction: up, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF3 } ]
      - name: Right stick right
        source_event: { gamepad: { axis: { name: RightStick, direction: right, deadzone: 0.4 } } }
        target_events: [ { keyboard: KeyF4 } ]
      - name: Right stick analog
        source_event: { gamepad: { axis: { name: RightStick } } }
        target_events: [ { gamepad: { axis: { name: RightStick } } } ]
      - name: Close chord
        source_event: { gamepad: { button: RightStick } }
        target_events: [ { keyboard: KeyF12 } ]
      - name: Radial outer ring
        source_event: { gamepad: { button: LeftBumper } }
        target_events: [ { keyboard: KeyF11 } ]
      - name: Left click
        source_event: { gamepad: { button: RightBumper } }
        target_events: [ { mouse: { button: Left } } ]
      - name: Control center
        source_event: { gamepad: { button: QuickAccess } }
        target_events: [ { keyboard: KeyF10 } ]
      - name: App launcher
        source_event: { gamepad: { button: Select } }
        target_events: [ { keyboard: KeyF24 } ]
      - name: Super modifier
        source_event: { gamepad: { trigger: { name: LeftTrigger, deadzone: 0.3 } } }
        target_events: [ { keyboard: KeyLeftMeta } ]
      - name: Move modifier
        source_event: { gamepad: { button: LeftPaddle1 } }
        target_events: [ { keyboard: KeyLeftShift } ]
      - name: Resize modifier
        source_event: { gamepad: { button: RightPaddle1 } }
        target_events: [ { keyboard: KeyLeftCtrl } ]
      - name: Activate
        source_event: { gamepad: { button: South } }
        target_events: [ { keyboard: KeyEnter } ]
      - name: Escape
        source_event: { gamepad: { button: East } }
        target_events: [ { keyboard: KeyEsc } ]
      # This Deck driver calls physical X North and physical Y West.
      - name: Overview
        source_event: { gamepad: { button: West } }
        target_events: [ { keyboard: KeyF21 } ]
      - name: On-screen keyboard
        source_event: { gamepad: { button: North } }
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
  keyboardInputProfile = pkgs.writeText "hyprland-keyboard-input.yaml" ''
    version: 1
    kind: DeviceProfile
    name: Steam Keyboard
    target_devices: [ deck-uhid, keyboard ]
    mapping:
      - name: Steam button
        source_event: { gamepad: { button: Guide } }
        target_events: [ { keyboard: KeyF23 } ]
      - name: Control center
        source_event: { gamepad: { button: QuickAccess } }
        target_events: [ { keyboard: KeyF10 } ]
  '';
  releaseInput = pkgs.writeShellScriptBin "deck-input-release" ''
    if ${deckInputPlumber}/bin/inputplumber device 0 info >/dev/null 2>&1; then
      ${deckInputPlumber}/bin/inputplumber device 0 profile load \
        ${deckInputPlumber}/share/inputplumber/profiles/default.yaml || true
    fi
    ${deckInputPlumber}/bin/inputplumber devices manage-all || true
  '';
  startCanvas = pkgs.writeShellScriptBin "start-hyprland-canvas" ''
    release() {
      ${gamingMode}/bin/deck-gaming-mode cleanup || true
      ${releaseInput}/bin/deck-input-release
    }
    trap release EXIT
    trap 'exit 1' INT TERM
    ${gamingMode}/bin/deck-gaming-mode cleanup
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
    runtimeInputs = [ canvas deckInputPlumber pkgs.jq pkgs.systemd pkgs.util-linux pkgs.coreutils pkgs.procps pkgs.libnotify ];
    text = builtins.readFile ../../dotfiles/hyprland/.config/hypr/scripts/deck-gaming-mode;
  };
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
in
{
  imports = [ ./hardware-configuration.nix ./keyboard.nix ./apps.nix ];

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

  jovian.decky-loader = {
    enable = true;
    user = "daphen";
    stateDir = "/home/daphen/homebrew";
  };
  home-manager.users.daphen.home.file.".local/share/Steam/.cef-enable-remote-debugging".text = "";

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
  programs.steam.extest.enable = true;
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
  environment.etc."inputplumber/profiles/hyprland-keyboard.yaml".source = keyboardInputProfile;
  systemd.user.slices.deck-work = {
    description = "Desktop work paused during Deck Game Mode";
    wantedBy = [ "default.target" ];
  };
  environment.sessionVariables = {
    HYPR_CANVAS_PROFILE = "deck";
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };
  environment.systemPackages = with pkgs; [
    canvas
    canvasSession
    gamingMode
    gamingModeEntry
    deckInputPlumber
    adwaita-icon-theme
    wev
    fish
    git
    vim
    kitty
    quickshell
    swaylock-effects
    swayidle
    brightnessctl
    playerctl
    wireplumber
    networkmanager
    bluez
    libnotify
    wtype
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
