#!/usr/bin/env bash
# Point the current theme mode's wallpaper symlink at $1.
#
# Used by the wallpaper picker to adopt an image as the default for whichever
# mode is active.
set -euo pipefail

img="${1:-}"
[ -z "$img" ] && { echo "usage: link-mode-wallpaper.sh <image>" >&2; exit 1; }

# waypaper escapes spaces in $wallpaper; undo before touching the filesystem.
img="${img//\\ / }"
img="$(realpath -e "$img")" || { echo "no such image: $1" >&2; exit 1; }

mode="$(cat "$HOME/.config/theme_mode" 2>/dev/null || echo dark)"
[ "$mode" = "light" ] || mode="dark"

link="$HOME/.config/themes/wallpaper-$mode"

# No-op when theme-manager re-applies the mode's own wallpaper — avoids
# rewriting the symlink (and churning git) with an identical target.
[ "$(readlink -f "$link" 2>/dev/null)" = "$img" ] && exit 0

ln -sfn "$img" "$link"
touch "$HOME/.config/theme_mode"
echo "wallpaper-$mode -> $img"
