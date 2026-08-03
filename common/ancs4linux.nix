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

  # Everything about this stack fails SILENTLY: the observer logs "Asking for
  # notifications: success" whether or not the phone honours the subscription, so
  # the only trustworthy signal is Notifying on the ANCS notification-source
  # characteristic. The readvertise hook covers boot and resume, but a plain walk
  # out of Bluetooth range — lid open, no suspend — hits neither, and the
  # observer then retries stale GATT paths and goes deaf with no symptom.
  #
  # So poll the one honest signal and self-heal. Restarting is a blunt fix for
  # the stale-path bug, but it covers causes we have not diagnosed too.
  watchdog = pkgs.writeShellScript "ancs4linux-watchdog" ''
    set -u
    PATH=${pkgs.lib.makeBinPath [ ancs4linux pkgs.jq pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.gawk ]}:$PATH

    NSRC=22eac6e9-24d6-4bb5-be44-b36ace7c7bfb   # ANCS notification source
    STAMP=/run/ancs4linux-watchdog.last
    FAILS=/run/ancs4linux-watchdog.fails
    COOLDOWN=120
    MAXFAILS=3

    # Advertising lapses on its own; without it a phone that wandered off has
    # nothing to reconnect to.
    #
    # The signal is LEAdvertisingManager1.ActiveInstances, NOT Adapter1
    # .Discoverable — Discoverable is classic-Bluetooth discoverability and stays
    # true regardless, so keying off it made this branch dead code: observed
    # ActiveInstances=1 alongside Discoverable=true, and equally a lapsed
    # advertisement would have gone unnoticed.
    hci=$(ancs4linux-ctl get-all-hci 2>/dev/null | jq -r '.[0] // empty') || true
    if [ -n "$hci" ]; then
      adv=$(busctl --system get-property org.bluez /org/bluez/hci0 \
              org.bluez.LEAdvertisingManager1 ActiveInstances 2>/dev/null | awk '{print $2}')
      if [ "''${adv:-0}" = "0" ]; then
        ancs4linux-ctl enable-advertising --hci-address "$hci" --name proart >/dev/null 2>&1 || true
        ancs4linux-ctl disable-pairing >/dev/null 2>&1 || true
      fi
    fi

    # BlueZ keeps the whole GATT tree cached for a BONDED device after it
    # disconnects — including a stale Notifying=true. Reading the characteristic
    # alone therefore says "healthy" for a phone that is nowhere near. Gate on
    # the parent device's Connected instead, so "subscribed" only counts when
    # there is a live link to be subscribed over.
    notifying=""
    devpath=""
    for c in $(busctl --system tree org.bluez 2>/dev/null \
                 | grep -oE '/org/bluez/hci[0-9]+/dev_[0-9A-F_]+/service[0-9a-f]+/char[0-9a-f]+'); do
      u=$(busctl --system get-property org.bluez "$c" \
            org.bluez.GattCharacteristic1 UUID 2>/dev/null | tr -d 's "')
      [ "$u" = "$NSRC" ] || continue
      d=$(printf '%s' "$c" | grep -oE '^/org/bluez/hci[0-9]+/dev_[0-9A-F_]+')
      conn=$(busctl --system get-property org.bluez "$d" \
               org.bluez.Device1 Connected 2>/dev/null | awk '{print $2}')
      [ "$conn" = "true" ] || continue
      devpath="$d"
      notifying=$(busctl --system get-property org.bluez "$c" \
                    org.bluez.GattCharacteristic1 Notifying 2>/dev/null | tr -d 'b ')
      break
    done

    # No CONNECTED device exposing ANCS: the phone is away. Nothing to heal, and
    # advertising was already re-asserted above so it can come back.
    [ -n "$devpath" ] || exit 0
    if [ "$notifying" = "true" ]; then
      rm -f "$FAILS"
      exit 0
    fi

    now=$(date +%s)
    if [ -f "$STAMP" ]; then
      last=$(cat "$STAMP" 2>/dev/null || echo 0)
      [ $((now - last)) -lt $COOLDOWN ] && exit 0
    fi
    printf '%s' "$now" > "$STAMP"

    # Restarting the observer only helps when the observer is the problem. When
    # the PHONE is refusing the subscription — it accepts StartNotify and then
    # never sets the CCCD, which so far has only cleared by re-pairing — retrying
    # forever just churns the daemon every couple of minutes and buries the real
    # signal. Give up after a few tries and say so once.
    n=$(cat "$FAILS" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s' "$n" > "$FAILS"
    if [ "$n" -gt "$MAXFAILS" ]; then
      [ "$n" = "$((MAXFAILS + 1))" ] && echo \
        "ANCS subscription still dead after $MAXFAILS restarts; the phone is refusing it — re-pair needed. Not retrying."
      exit 0
    fi

    echo "ANCS subscription dead while phone is connected; restarting observer (attempt $n/$MAXFAILS)"
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

  # Polls the one honest health signal and self-heals. Ordered after the
  # readvertise hook so a boot does not race it.
  systemd.services.ancs4linux-watchdog = {
    description = "Heal the ANCS subscription if it has silently died";
    after = [ "bluetooth.service" "ancs4linux-readvertise.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${watchdog}";
      TimeoutStartSec = "90s";
    };
  };

  systemd.timers.ancs4linux-watchdog = {
    description = "Periodic ANCS subscription health check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min";
      # A missed call is the failure this exists to prevent, so catch up rather
      # than skip if the machine was asleep.
      Persistent = true;
    };
  };

  # The user-side daemon that turns these notifications into desktop ones sits
  # with the other user daemons in common/home/daemons.nix.
}
