#!/usr/bin/env bash
set -euo pipefail

start_unit() {
  local unit=$1
  local config=$2
  local restart=${3:-always}

  if systemctl --user is-active --quiet "$unit"; then
    echo "$unit is already running."
    return
  fi

  if [[ $(systemctl --user show "$unit" -p LoadState --value 2>/dev/null) == "not-found" ]]; then
    systemd-run --user --unit="${unit%.service}" \
      --property=Restart=always \
      --property=RestartSec=1s \
      /run/current-system/sw/bin/kanata --cfg "$config"
  else
    systemctl --user reset-failed "$unit" 2>/dev/null || true
    systemctl --user start "$unit"
  fi
}

# A per-device instance whose keyboard is ABSENT exits immediately, and
# Restart=always then restarts it every second forever. Each start creates a fresh
# uinput device, so /dev/input churns once a second, the other instance's
# device-watcher rescans on every event, and the real keyboard's output competes
# with a virtual keyboard appearing and vanishing continuously — doubled keys and
# stalls. Seen 2026-09-10, the first boot after this charybdis rule was added:
# 156 charybdis starts in one boot with the keyboard unplugged.
charybdis_present() { ls /dev/input/by-id/ 2>/dev/null | grep -qiE "charybdis"; }

start_unit kanata-session.service "$HOME/.config/kanata/kanata.kbd"
if charybdis_present; then
  start_unit kanata-charybdis.service "$HOME/.config/kanata/kanata-charybdis.kbd" no-restart
else
  echo "charybdis not connected — skipping kanata-charybdis (re-run this script after plugging it in)"
fi

sleep 3
systemctl --user is-active --quiet kanata-session.service
echo "Kanata services started."
echo "Logs: journalctl --user -u kanata-session -u kanata-charybdis -f"
