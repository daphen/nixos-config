# iPhone notifications on the desktop over Bluetooth LE, via Apple's
# Notification Center Service (ANCS) — the protocol smartwatches use. The
# point here is the IncomingCall category: a ringing phone shows up on screen
# even when it is face-down or silent.
#
# Deliberately NOT Bluetooth HFP: that pairs the phone as a hands-free unit,
# which invites iOS to route call audio to the laptop and would change the
# HFP backend our AirPods/Px8 negotiate with. ANCS is BLE GATT only, carries
# no audio, and ancs4linux additionally blocks the phone's audio redirect
# during pairing.
{ config, pkgs, ... }:

let
  ancs4linux = import ../pkgs/ancs4linux { inherit pkgs; };

  # Upstream's policy grants the ancs4linux GROUP, but supplementary groups are
  # fixed when a process starts — so the systemd --user manager only picks the
  # group up at next login, and user units can't set SupplementaryGroups=
  # themselves (no privileges). Granting the user directly makes the unit work
  # the moment it is switched on, on a fresh machine or after adding this.
  userPolicy = pkgs.writeTextFile {
    name = "ancs4linux-user-dbus-policy";
    destination = "/share/dbus-1/system.d/ancs4linux-user.conf";
    text = ''
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
       "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy user="daphen">
          <allow send_destination="ancs4linux.Observer"/>
          <allow receive_sender="ancs4linux.Observer"/>
          <allow send_destination="ancs4linux.Advertising"/>
          <allow receive_sender="ancs4linux.Advertising"/>
        </policy>
      </busconfig>
    '';
  };
in
{
  environment.systemPackages = [ ancs4linux ];

  # The two root daemons own names on the SYSTEM bus; this group is what lets
  # a normal user talk to them (ancs4linux-ctl, desktop-integration).
  users.groups.ancs4linux = { };
  users.users.daphen.extraGroups = [ "ancs4linux" ];

  services.dbus.packages = [ ancs4linux userPolicy ];

  systemd.services.ancs4linux-observer = {
    description = "ancs4linux Observer daemon";
    requires = [ "bluetooth.service" ];
    after = [ "bluetooth.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "dbus";
      BusName = "ancs4linux.Observer";
      ExecStart = "${ancs4linux}/bin/ancs4linux-observer";
      Restart = "on-failure";
    };
  };

  systemd.services.ancs4linux-advertising = {
    description = "ancs4linux Advertising daemon";
    requires = [ "bluetooth.service" ];
    after = [ "bluetooth.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "dbus";
      BusName = "ancs4linux.Advertising";
      ExecStart = "${ancs4linux}/bin/ancs4linux-advertising";
      Restart = "on-failure";
    };
  };

  # The user-side daemon that turns these notifications into desktop ones sits
  # with the other user daemons in common/home/daemons.nix.
}
