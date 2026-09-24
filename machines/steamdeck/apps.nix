{ pkgs, inputs, applicationPkgs, ... }:

let
  paletteDaemon = inputs.palette-daemon.packages.${pkgs.system}.default;
  openwhispr = pkgs.callPackage ../../pkgs/openwhispr { };
  agentd = import ../../pkgs/agentd { pkgs = applicationPkgs; src = inputs.agentd; };
  cockpit = pkgs.writeShellScriptBin "deck-cockpit" ''
    export COCKPIT_INSTANCE=personal COCKPIT_SCOPE=personal COCKPIT_DECK=1
    export COCKPIT_AGENTD_SOCKS="$XDG_RUNTIME_DIR/agentd-personal.sock,$XDG_RUNTIME_DIR/agentd-proart-personal.sock"
    ln -sfn "$XDG_RUNTIME_DIR/agentd-proart-work.sock" "$XDG_RUNTIME_DIR/agentd-work.sock"
    export COCKPIT_NEW_CWD="$HOME/personal"
    mkdir -p "$COCKPIT_NEW_CWD"
    exec "$HOME/.config/hypr/scripts/jump-or-exec" "cockpit-qs · private" \
      "$HOME/.config/hypr/scripts/desktop-launch cockpit-qs"
  '';
in
{
  imports = [ ../../common/applications.nix ];

  programs.nix-ld.enable = true;

  home-manager.users.daphen = { config, lib, nvimLocal, nvimBaked, ... }: {
    imports = [ (import ../../common/home/programs.nix {
      pkgs = applicationPkgs;
      inherit inputs nvimLocal nvimBaked;
    }) {
      xdg.desktopEntries = lib.mapAttrs (command: name: {
        inherit name;
        exec = "${config.home.homeDirectory}/.config/hypr/scripts/desktop-launch ${command}";
        terminal = false;
        categories = [ "Utility" ];
      }) {
        dsqrd-client = "Discord (dsqrd)";
        slqs-client = "Slack (slqs)";
        mlqs-client = "Mail (mlqs)";
        opqs-client = "Passwords (opqs)";
        deck-cockpit = "Cockpit";
      };
    } ];
    home.packages = [
      cockpit
      applicationPkgs.python3
      pkgs.gnome-keyring
      pkgs.gcr
      (import ../../pkgs/desktopctl { pkgs = applicationPkgs; })
    ];
    xdg.dataFile."dbus-1/services/org.freedesktop.secrets.service".text = ''
      [D-BUS Service]
      Name=org.freedesktop.secrets
      Exec=${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --foreground --components=secrets
    '';
    xdg.configFile."hypr/deck-share-picker" = {
      executable = true;
      text = ''
        #!/bin/sh
        printf '[SELECTION]/screen:eDP-1\n'
      '';
    };
    xdg.configFile."hypr/xdph.conf".text = ''
      screencopy {
          custom_picker_binary = ${config.xdg.configHome}/hypr/deck-share-picker
      }
    '';
    xdg.configFile."quickmarks".source = config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos/dotfiles/quickmarks/.config/quickmarks";
    xdg.configFile."helium-personal/NativeMessagingHosts/com.daphen.quickmarks.json".source =
      ../../dotfiles/quickmarks/.config/net.imput.helium/NativeMessagingHosts/com.daphen.quickmarks.json;
    xdg.configFile."net.imput.helium/NativeMessagingHosts/com.daphen.quickmarks.json".source =
      ../../dotfiles/quickmarks/.config/net.imput.helium/NativeMessagingHosts/com.daphen.quickmarks.json;
    home.file.".local/bin/agentd".source = "${agentd}/bin/agentd";
    home.file.".local/bin/launch-agentd".source = ../../dotfiles/niri/.config/niri/scripts/launch-agentd;
    home.file.".pi/agent/roles".source = config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos/dotfiles/ai/roles";

    systemd.user.services.agentd-personal = {
      Unit = {
        Description = "agentd (personal scope)";
        After = [ "network-online.target" "graphical-session.target" ];
      };
      Service = {
        ExecStart = "%h/.local/bin/launch-agentd personal --repo %h/personal";
        Environment = "PATH=${pkgs.libsecret}/bin:${pkgs.fish}/bin:/etc/profiles/per-user/daphen/bin:/run/current-system/sw/bin";
        Restart = "on-failure";
        RestartSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };

    xdg.desktopEntries.google-chrome = lib.mkForce { name = "Google Chrome"; noDisplay = true; };

    # Hide Helium's generic entry: it bypasses the isolated personal data dir.
    xdg.desktopEntries.helium = {
      name = "Helium";
      noDisplay = true;
    };
    xdg.desktopEntries.helium-personal = {
      name = "Helium (Personal)";
      exec = "${config.home.homeDirectory}/.config/hypr/scripts/chromium-launch %U";
      icon = "helium";
      terminal = false;
      type = "Application";
      categories = [ "Network" "WebBrowser" ];
      mimeType = [ "application/pdf" "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
    };
    xdg.desktopEntries.command-palette = {
      name = "Command Palette";
      exec = "${config.home.homeDirectory}/.config/hypr/scripts/palette-toggle";
      icon = "system-search";
      terminal = false;
      type = "Application";
      categories = [ "Utility" ];
    };

    systemd.user.services.openwhispr = {
      Unit = {
        Description = "OpenWhispr local voice dictation";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStartPre = "/bin/sh -c '[ -n \"$WAYLAND_DISPLAY\" ] && (${pkgs.procps}/bin/pkill -u %U -f \"openwhispr-[^/]*/resources/bin/[l]inux-key-listener-x64\" || true)'";
        ExecStart = "${openwhispr}/bin/openwhispr --no-sandbox --ozone-platform=wayland";
        ExecStopPost = "/bin/sh -c '${pkgs.procps}/bin/pkill -u %U -f \"openwhispr-[^/]*/resources/bin/[l]inux-key-listener-x64\" || true; ${pkgs.coreutils}/bin/rm -f %t/openwhispr-dictation-state'";
        Environment = [
          "DICTATION_KEY=Super+F9"
          "OPENWHISPR_EXTERNAL_DICTATION_KEY=Super+F9"
          "OPENWHISPR_EXTERNAL_HOTKEY=1"
          "OPENWHISPR_EXTERNAL_OVERLAY=1"
          "OPENWHISPR_FORCE_PUSH_TO_TALK=1"
          "LOCAL_TRANSCRIPTION_PROVIDER=nvidia"
          "PARAKEET_MODEL=orukeet-v0.1.0"
          "DICTATION_LANGUAGE=auto"
          "CLEANUP_PROVIDER=local"
          "LOCAL_CLEANUP_MODEL=lfm2.5-1.2b-instruct-q4_k_m"
          "DICTATION_AGENT_PROVIDER=local"
          "LOCAL_DICTATION_AGENT_MODEL=lfm2.5-1.2b-instruct-q4_k_m"
        ];
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.palette-daemon = {
      Unit = {
        Description = "Palette Daemon (browser state mirror for the Quickshell palette)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStartPre = "/bin/sh -c '[ -n \"$WAYLAND_DISPLAY\" ]'";
        ExecStart = "${paletteDaemon}/bin/palette-daemon";
        Environment = [ "PALETTE_HEADLESS=1" "RUST_LOG=palette_daemon=info" ];
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
