{ pkgs, ... }:
let
  src = "%h/.claude/projects/";
  dest = "%h/.local/state/claude-transcript-backups/mirror/";
in
{
  systemd.user.services.claude-transcript-backup = {
    Unit.Description = "Append-only mirror of Claude Code transcripts";
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${dest}";
      # No --delete: a transcript that vanishes from the source is kept here,
      # so an accidental deletion (or crash) can never lose a conversation.
      ExecStart = "${pkgs.rsync}/bin/rsync -a ${src} ${dest}";
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
}
