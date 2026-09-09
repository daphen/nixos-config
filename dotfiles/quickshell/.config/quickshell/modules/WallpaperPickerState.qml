pragma Singleton

import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property bool open: false

    function toggle() { open = !open }
    function show() { open = true }
    function hide() { open = false }

    IpcHandler {
        target: "wallpaper-picker"
        function toggle() { root.toggle() }
    }
}
