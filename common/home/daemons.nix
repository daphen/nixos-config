# Every long-running user daemon (and the one periodic timer) in one place.
#
# Machine-scoped hardware units deliberately stay in machines/<host>/ — the
# nvidia/lid/usb-wakeup quirks only apply to one laptop, and hoisting them here
# would fire them on thinkpad and zenbook too.
{ pkgs, inputs, ... }:
let
  # One launch path for every local agentd scope: the wrapper pulls provider
  # secrets keyring→env (see niri/scripts/launch-agentd) and execs the daemon —
  # a unit restart can never again produce a keyless daemon.
  mkAgentd = { scope, description, extraArgs }: {
    Unit = {
      Description = description;
      After = [ "network-online.target" "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      Environment = "PATH=${pkgs.libsecret}/bin:/run/current-system/sw/bin";
      ExecStart = "%h/.config/niri/scripts/launch-agentd ${scope} ${extraArgs}";
      Restart = "on-failure";
      RestartSec = "10s";
    };
    Install.WantedBy = [ "default.target" ];
  };
  palette-daemon = inputs.palette-daemon.packages.${pkgs.system}.default;
  ancs4linux = import ../../pkgs/ancs4linux { inherit pkgs; };

  claudeBackupSrc = "%h/.claude/projects/";
  claudeBackupDest = "%h/.local/state/claude-transcript-backups/mirror/";
in
{
  # Burst-based WPM counter. Reads /dev/input/event* (needs the `input` group,
  # added in common/default.nix) and writes to ~/.local/state/wpm, where the QS
  # Wpm widget picks it up. Local-source build; lives at ~/personal/wpm-daemon.
  systemd.user.services.wpm-daemon = {
    Unit = {
      Description = "WPM daemon — keystroke rate counter for the QS bar";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/personal/wpm-daemon/target/release/wpm-daemon";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Runs headless — quickshell renders the palette UI over palette-ui.sock, so
  # the daemon loads no popup bundle. The SW half of chromium-palette is loaded
  # unpacked from ~/personal/chromium-palette/dist.
  systemd.user.services.palette-daemon = {
    Unit = {
      Description = "Palette Daemon (browser state mirror for the quickshell palette)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      # A failed pre-check RETRIES via Restart (re-reading the manager env each
      # attempt); ExecCondition would skip permanently — which is how a boot
      # where WAYLAND_DISPLAY landed late left the palette dead.
      ExecStartPre = "/bin/sh -c '[ -n \"$WAYLAND_DISPLAY\" ]'";
      ExecStart = "${palette-daemon}/bin/palette-daemon";
      Environment = [
        "PALETTE_HEADLESS=1"
        "RUST_LOG=palette_daemon=info"
      ];
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Turns an iPhone ANCS notification into a desktop notification. The root
  # observer/advertising daemons that feed it live in common/ancs4linux.nix,
  # since those need system-bus names and a D-Bus policy.
  systemd.user.services.ancs4linux-desktop-integration = {
    Unit = {
      Description = "ancs4linux desktop integration (iPhone notifications)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${ancs4linux}/bin/ancs4linux-desktop-integration";
      # Only calls and texts reach the desktop; an unfiltered phone mirrors
      # every app's notifications. Bundle ids, not ANCS categories — Messages
      # reports as category Social, which would also admit Messenger/WhatsApp.
      # Empty or unset = allow everything (upstream behaviour).
      Environment = [
        "ANCS_APP_ALLOWLIST=com.apple.mobilephone,com.apple.MobileSMS,com.apple.facetime"
      ];
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.notes-sync = {
    Unit = {
      Description = "notes-cli watch: keep local vault in sync with webapp";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/personal/notes/cli/notes-cli -watch";
      Restart = "on-failure";
      RestartSec = "10s";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # The LOCAL orchestrator's daemon; per-ticket work runs remotely in the `work`
  # scope. chat backs the newtab/palette AI; personal backs the private heidr.
  # chat + personal were niri-spawned with stdin key injection until now — a
  # restart outside that path made them keyless (the Aug-16 newtab outage).
  systemd.user.services.agentd-lovable = mkAgentd {
    scope = "lovable";
    description = "agentd (lovable scope) — local orchestrator + PR reviewers";
    extraArgs = "--repo %h/work/lovable";
  };
  systemd.user.services.agentd-chat = mkAgentd {
    scope = "chat";
    description = "agentd (chat scope) — newtab + palette chat sessions";
    extraArgs = "--repo %h/.local/share/agentd/chat";
  };
  systemd.user.services.agentd-personal = mkAgentd {
    scope = "personal";
    description = "agentd (personal scope) — private heidr sessions";
    extraArgs = "--repo %h/personal";
  };

  # The VM work-scope daemon reaches this machine as a unix-socket forward over ssh.
  # It was a bare hand-started `ssh -L`, so every suspend/network change killed it and
  # left a corpse socket refusing connections — the rail then re-dialed it every 2s,
  # flooding the log, and the work cockpit went blind until someone remembered the
  # incantation. Supervised now: restart on ANY exit, StreamLocalBindUnlink clears the
  # stale socket file on rebind, keepalives detect a dead path in ~60s.
  systemd.user.services.agentd-work-tunnel = {
    Unit = {
      Description = "agentd work-scope tunnel (VM unix-socket forward)";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.openssh}/bin/ssh -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ConnectTimeout=15 -L %t/agentd-work.sock:127.0.0.1:17840 david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net";
      Restart = "always";
      RestartSec = "5s";
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.claude-transcript-backup = {
    Unit.Description = "Append-only mirror of Claude Code transcripts";
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${claudeBackupDest}";
      # No --delete: a transcript that vanishes from the source is kept here,
      # so an accidental deletion (or crash) can never lose a conversation.
      ExecStart = "${pkgs.rsync}/bin/rsync -a ${claudeBackupSrc} ${claudeBackupDest}";
    };
  };

  systemd.user.timers.claude-transcript-backup = {
    Unit.Description = "Periodic append-only backup of Claude transcripts";
    Timer = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Export pi agent sessions into the notes vault as markdown transcripts, so
  # agent conversations become durable + searchable via notes-memory (the notes
  # watcher above syncs them up). Explicit python3 — a user unit's PATH may lack it.
  systemd.user.services.pi-to-vault = {
    Unit.Description = "Export pi agent sessions into the notes vault";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 %h/.local/bin/pi-to-vault";
    };
  };

  systemd.user.timers.pi-to-vault = {
    Unit.Description = "Periodic pi-session → vault export";
    Timer = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Refresh the agent-rail orchestrator dashboard's Linear cycle cache
  # (~/.local/state/lovable/cycle.json) — deterministic API fetch, no LLM. Reads
  # LINEAR_API_KEY from ~/.config/fish/secrets.fish. Explicit PATH: a user unit's
  # PATH lacks curl/jq/sed. Exits cleanly (no cache clobber) when the token is the
  # placeholder or there's no active cycle, so it's harmless until the key is set.
  systemd.user.services.cycle-sync = {
    Unit.Description = "Refresh the Linear cycle cache for the agent-rail dashboard";
    Service = {
      Type = "oneshot";
      Environment = "PATH=${pkgs.lib.makeBinPath [ pkgs.bash pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gnugrep ]}";
      ExecStart = "${pkgs.bash}/bin/bash %h/.local/bin/cycle-sync";
    };
  };

  systemd.user.timers.cycle-sync = {
    Unit.Description = "Periodic Linear cycle cache refresh";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Post the morning /daily briefing to the Synced new-tab card, headlessly. This
  # one drives `pi` (needs LLM curation + Company Brain/Slack MCPs), off the
  # Lovable OpenAI key. The script sets its own PATH; the unit just runs it.
  systemd.user.services.daily-sync = {
    Unit.Description = "Post the morning /daily briefing to the Synced card";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash %h/.local/bin/daily-sync";
    };
  };

  systemd.user.timers.daily-sync = {
    Unit.Description = "Morning /daily briefing";
    Timer = {
      OnCalendar = "*-*-* 07:00:00";
      Persistent = true; # if the machine was asleep at 07:00, run at next wake
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
