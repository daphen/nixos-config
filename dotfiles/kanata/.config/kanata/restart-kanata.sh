#!/usr/bin/env bash
set -euo pipefail

systemctl --user stop kanata-live.service kanata-session.service kanata-charybdis.service 2>/dev/null || true
if pgrep -x kanata >/dev/null; then
  pkill -x kanata 2>/dev/null || /run/wrappers/bin/sudo pkill -x kanata
fi
sleep 1
exec "$HOME/.config/kanata/start-kanata.sh"
