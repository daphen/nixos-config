#!/usr/bin/env bash

# Open-Meteo (keyless), not wttr.in: wttr's backend periodically serves stale
# or garbage observations (2026-08-14: "Blizzard, -4°C" for Stockholm in
# August). Open-Meteo returns a WMO weather code + temperature as clean JSON.
# --max-time so a slow API can't leave the Process (and the bar module) stuck
# forever with no output; --retry rides out transient blips.
data=$(curl -s --max-time 8 --retry 1 \
  'https://api.open-meteo.com/v1/forecast?latitude=59.33&longitude=18.07&current_weather=true')
# No data (network down at poll time) → emit nothing; the module hides and
# Weather.qml retries soon instead of showing a bare/wrong icon.
[ -z "$data" ] && exit 0

read -r code temp < <(python3 -c "
import json, sys
try:
    c = json.loads(sys.argv[1])['current_weather']
    print(int(c['weathercode']), round(float(c['temperature'])))
except Exception:
    pass
" "$data")
[ -z "${temp:-}" ] && exit 0

# WMO weather codes → the same Nerd Font glyphs the old wttr mapping used
case "$code" in
  95|96|99)             icon="󰖓" ;;   # thunderstorm
  65|67|82)             icon="󰖖" ;;   # heavy rain / freezing rain / violent showers
  51|53|55|56|57|61|80) icon="󰖗" ;;   # drizzle / light rain / light showers
  63|81)                icon="󰖖" ;;   # rain / showers
  75|77|86)             icon="󰼶" ;;   # heavy snow / snow grains / heavy snow showers
  71|73|85)             icon="󰖘" ;;   # snow
  45|48)                icon="󰖑" ;;   # fog
  3)                    icon="󰅟" ;;   # overcast (filled cloud)
  1|2)                  icon="󰖕" ;;   # partly cloudy (sun+cloud)
  0)                    icon="󰖨" ;;   # clear (filled sun)
  *)                    icon="󰅟" ;;   # default: filled cloud
esac

echo "$icon ${temp}°C"
