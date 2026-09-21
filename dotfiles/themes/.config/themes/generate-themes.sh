#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/theme-manager.sh" generate dark
"$SCRIPT_DIR/theme-manager.sh" generate light
"$SCRIPT_DIR/theme-manager.sh" apply
