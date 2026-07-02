#!/usr/bin/env sh
# Copy the image imv is currently displaying to the Wayland clipboard.
# imv exports $imv_current_file to exec'd commands and splits bind lines on ';',
# so the logic lives here (a script has no ';' for imv to choke on). Bound to `y`.
# setsid so wl-copy's background clipboard server outlives imv's exec cleanup.
f="$imv_current_file"
[ -n "$f" ] || exit 0
case "${f##*.}" in
    jpg|jpeg) t=image/jpeg ;;
    gif) t=image/gif ;;
    webp) t=image/webp ;;
    *) t=image/png ;;
esac
setsid wl-copy --type "$t" < "$f"
command -v notify-send >/dev/null 2>&1 && notify-send -t 1200 -a imv "Copied image to clipboard"
