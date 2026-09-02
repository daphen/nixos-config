#!/usr/bin/env bash
set -euo pipefail

start_unit() {
  local unit=$1
  local config=$2

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

start_unit kanata-session.service "$HOME/.config/kanata/kanata.kbd"
start_unit kanata-charybdis.service "$HOME/.config/kanata/kanata-charybdis.kbd"

sleep 3
systemctl --user is-active --quiet kanata-session.service
systemctl --user is-active --quiet kanata-charybdis.service
echo "Kanata services started."
echo "Logs: journalctl --user -u kanata-session -u kanata-charybdis -f"
