#!/usr/bin/env bash
ctl="$(command -v mediactl || true)"
[[ -n "$ctl" ]] || ctl="/etc/profiles/per-user/${USER:-${LOGNAME:-daphen}}/bin/mediactl"
exec "$ctl" view "$@"
