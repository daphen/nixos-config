#!/usr/bin/env bash
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ctl="$(command -v themectl || true)"
[[ -n "$ctl" ]] || ctl="/etc/profiles/per-user/${USER:-${LOGNAME:-daphen}}/bin/themectl"
THEMES_DIR="$dir" exec -a "$0" "$ctl" "$@"
