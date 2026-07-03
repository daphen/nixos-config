pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false

    // Fired by `showOrJump`; NotificationJumpPicker decides: exactly one toast
    // on screen → jump straight to it, else open the picker.
    signal jumpRequested()

    function toggle() { open = !open }
    function show()   { open = true }
    function hide()   { open = false }

    IpcHandler {
        target: "notification-jump"
        function toggle() { root.toggle() }
        function show()   { root.show() }
        function hide()   { root.hide() }
        function showOrJump() { root.jumpRequested() }
    }
}
