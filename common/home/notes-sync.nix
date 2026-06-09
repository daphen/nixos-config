{ config, pkgs, ... }:
{
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
}
