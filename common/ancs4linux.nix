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
  # ANCS needs the laptop ADVERTISING for the phone to reconnect to it — the
  # phone is the central, we are the peripheral. Nothing restored that after a
  # suspend, so closing the lid left the phone with nothing to find and
  # notifications silently stopped until `enable-advertising` was run by hand.
  #
  # The observer restart is a workaround, not elegance: BlueZ renumbers the GATT
  # object paths on reconnect and the observer caches them, so it retries the old
  # paths and fails with UnknownObject. Restarting makes it re-enumerate.
  readvertise = pkgs.writeShellScript "ancs4linux-readvertise" ''
    set -u
    # coreutils explicitly: systemd units get a minimal PATH, and seq/sleep
    # below would otherwise depend on whatever the unit happens to inherit.
    PATH=${pkgs.lib.makeBinPath [ ancs4linux pkgs.jq pkgs.systemd pkgs.coreutils ]}:$PATH

    # Post-resume the radio comes back via rfkill unblock, so the adapter may
    # not exist yet. Wait for it rather than racing.
    hci=""
    for _ in $(seq 1 30); do
      hci=$(ancs4linux-ctl get-all-hci 2>/dev/null | jq -r '.[0] // empty') || true
      [ -n "$hci" ] && break
      sleep 1
    done
    [ -n "$hci" ] || { echo "no BLE adapter after 30s; giving up"; exit 0; }

    ancs4linux-ctl enable-advertising --hci-address "$hci" --name proart || true
    # Advertise so a bonded phone can reconnect, but keep the pairing window
    # shut — enable-advertising opens both.
    ancs4linux-ctl disable-pairing || true
    systemctl restart ancs4linux-observer || true
  '';
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

  # Runs at boot and after every resume, so the phone always has something to
  # reconnect to. enable-advertising takes ~30s to settle, hence the timeout.
  systemd.services.ancs4linux-readvertise = {
    description = "Re-enable ANCS advertising and refresh the observer";
    after = [
      "bluetooth.service"
      "ancs4linux-advertising.service"
      "systemd-suspend.service"
      "systemd-hibernate.service"
      "systemd-suspend-then-hibernate.service"
    ];
    requires = [ "ancs4linux-advertising.service" ];
    wantedBy = [
      "multi-user.target"
      "systemd-suspend.service"
      "systemd-hibernate.service"
      "systemd-suspend-then-hibernate.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${readvertise}";
      TimeoutStartSec = "120s";
    };
  };

  # The user-side daemon that turns these notifications into desktop ones sits
  # with the other user daemons in common/home/daemons.nix.
}
