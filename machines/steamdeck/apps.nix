{ pkgs, inputs, applicationPkgs, ... }:

let
  paletteDaemon = inputs.palette-daemon.packages.${pkgs.system}.default;
  agentd = import ../../pkgs/agentd { pkgs = applicationPkgs; src = inputs.agentd; };
  cockpit = pkgs.writeShellScriptBin "deck-cockpit" ''
    export COCKPIT_INSTANCE=personal COCKPIT_SCOPE=personal
    export COCKPIT_AGENTD_SOCKS="$XDG_RUNTIME_DIR/agentd-personal.sock"
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
      (import ../../pkgs/desktopctl { pkgs = applicationPkgs; })
    ];
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
