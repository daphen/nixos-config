import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    WlSessionLock {
        id: lock
        locked: true
        onLockedChanged: if (!locked) Qt.quit()

        WlSessionLockSurface {
            color: "black"
        }
    }

    IpcHandler {
        target: "pocket"
        function unlock() { lock.locked = false }
    }
}
