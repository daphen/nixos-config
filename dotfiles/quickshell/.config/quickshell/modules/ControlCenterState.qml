pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property bool open: false

    IpcHandler {
        target: "controlCenter"
        function toggle() { root.open = !root.open }
    }
}
