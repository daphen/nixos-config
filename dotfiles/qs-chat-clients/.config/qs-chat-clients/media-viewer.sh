#!/usr/bin/env bash
if command -v mediactl >/dev/null 2>&1; then
    exec mediactl view "$@"
fi
exec "${BASH_SOURCE[0]%/*}/media-viewer.bash" "$@"
