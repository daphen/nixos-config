#!/usr/bin/env bash
export QML2_IMPORT_PATH="$HOME/.local/share/qml"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
exec qs -p "$(dirname "$0")"
