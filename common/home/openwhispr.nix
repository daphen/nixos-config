{ lib, pkgs, ... }:
let
  openwhispr = pkgs.callPackage ../../pkgs/openwhispr { };
in
{
  home.packages = [ pkgs.ydotool ];

  home.activation.removeYdotooldBootstrapUnit = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    unit="$HOME/.local/share/systemd/user/ydotoold.service"
    if [ -L "$unit" ] && [ "$(${pkgs.coreutils}/bin/readlink "$unit")" = "$HOME/nixos/machines/steamdeck/ydotoold.service" ]; then
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$unit"
    fi
  '';

  home.activation.removeOpenWhisprBootstrapUnit = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$HOME/.local/share/systemd/user/openwhispr.service"
  '';

  systemd.user.services.ydotoold = {
    Unit = {
      Description = "User ydotool input daemon";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.ydotool}/bin/ydotoold --socket-path=%t/.ydotool_socket --socket-perm=0600";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
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
}
