#!/usr/bin/env sh
# Copy the image imv is currently displaying to the Wayland clipboard.
# imv exports $imv_current_file to exec'd commands and splits bind lines on ';',
# so the logic lives here (a script has no ';' for imv to choke on). Bound to `y`.
# setsid so wl-copy's background clipboard server outlives imv's exec cleanup.
# jpeg/webp are converted to png: many paste targets only accept image/png, and
# clipse's history watcher only stores png — a raw jpeg copy silently vanishes.
f="$imv_current_file"
[ -n "$f" ] || exit 0
case "${f##*.}" in
    gif) setsid wl-copy --type image/gif < "$f" ;;
    jpg|jpeg|webp)
        if command -v magick >/dev/null 2>&1; then
            magick "$f" png:- | setsid wl-copy --type image/png
        else
            setsid wl-copy --type image/jpeg < "$f"
        fi ;;
    *) setsid wl-copy --type image/png < "$f" ;;
esac
command -v notify-send >/dev/null 2>&1 && notify-send -t 1200 -a imv "Copied image to clipboard"
