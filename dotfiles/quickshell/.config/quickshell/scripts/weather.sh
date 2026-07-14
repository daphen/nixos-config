#!/usr/bin/env bash

data=$(curl -s 'wttr.in/Stockholm?format=%C|%t')
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
