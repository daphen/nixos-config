#!/usr/bin/env bash

# --max-time so a slow/hung wttr.in can't leave the Process (and the bar
# module) stuck forever with no output; --retry rides out transient blips.
data=$(curl -s --max-time 8 --retry 1 'wttr.in/Stockholm?format=%C|%t')
# No data (network down at poll time) → emit nothing; the module hides and
# Weather.qml retries soon instead of showing a bare/wrong icon.
[ -z "${data//|/}" ] && exit 0
condition=$(echo "$data" | cut -d'|' -f1 | xargs)
# wttr prefixes positive temps with '+' — strip it, keep a real '-'
temp=$(echo "$data" | cut -d'|' -f2 | tr -d ' ' | sed 's/^+//')

condition_lower=$(echo "$condition" | tr '[:upper:]' '[:lower:]')

case "$condition_lower" in
  *"thunderstorm"*|*"thunder"*)       icon="󰖓" ;;
  *"heavy rain"*|*"heavy shower"*)    icon="󰖖" ;;
  *"light rain"*|*"light drizzle"*|*"patchy light rain"*|*"light shower"*) icon="󰖗" ;;
  *"rain"*|*"drizzle"*|*"shower"*)    icon="󰖖" ;;
  *"sleet"*)                          icon="󰙿" ;;
  *"blizzard"*|*"heavy snow"*)        icon="󰼶" ;;
  *"light snow"*|*"patchy light snow"*) icon="󰖘" ;;
  *"snow"*|*"ice"*)                   icon="󰖘" ;;
  *"mist"*|*"fog"*)                   icon="󰖑" ;;
  *"overcast"*)                       icon="󰅟" ;;   # filled cloud (nf-md-cloud)
  *"partly cloudy"*|*"patchy"*)       icon="󰖕" ;;   # no filled variant — sun+cloud
  *"cloudy"*|*"cloud"*)               icon="󰅟" ;;   # filled cloud
  *"clear"*|*"sunny"*)                icon="󰖨" ;;   # filled sun (white-balance-sunny)
  *)                                  icon="󰅟" ;;   # default: filled cloud
esac

echo "$icon $temp"
