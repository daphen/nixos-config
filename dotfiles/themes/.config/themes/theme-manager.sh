#!/usr/bin/env bash
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if command -v theme-manager >/dev/null 2>&1; then THEMES_DIR="$dir" exec -a "$0" theme-manager "$@"; fi
exec bash -c 'file=$1; shift; source "$file"' "$0" "$dir/theme-manager.bash" "$@"
