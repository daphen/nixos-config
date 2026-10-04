import QtQuick
import Quickshell
import Quickshell.Services.Pam
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property bool nativeCanvas: Quickshell.env("HYPR_CANVAS_NATIVE_LOCK") === "1"
    property string pendingResponse: ""
    property bool unlocking: false

    signal authenticationStarted()
    signal authenticationFailed()
    signal unlockStarted()

    function beginAuthentication(password) {
        if (pam.active || unlocking) return
        pendingResponse = password
        authenticationStarted()
        if (!pam.start()) {
            pendingResponse = ""
            authenticationFailed()
        }
    }

    PamContext {
        id: pam
        config: "swaylock"
        user: Quickshell.env("USER")

        onResponseRequiredChanged: {
            if (!responseRequired || !root.pendingResponse.length) return
            respond(root.pendingResponse)
            root.pendingResponse = ""
        }
        onCompleted: result => {
            root.pendingResponse = ""
            if (result === PamResult.Success) {
                root.unlocking = true
                root.unlockStarted()
                unlockDelay.restart()
            } else {
                root.authenticationFailed()
            }
        }
    }

    WlSessionLock {
        id: sessionLock
        locked: true

        WlSessionLockSurface {
            id: surface
            color: root.nativeCanvas ? "transparent" : "#050607"

            LoginView {
                id: login
                visible: !root.nativeCanvas
                width: surface.width
                height: surface.height
                deckMode: Quickshell.env("HYPR_CANVAS_PROFILE") === "deck" || width <= 1280
                showLoginControls: false
            }

            LockBar {
                id: lockBar
                width: surface.width
                onPasswordSubmitted: password => root.beginAuthentication(password)
            }

            Connections {
                target: root
                function onAuthenticationStarted() { lockBar.authState = "authenticating" }
                function onAuthenticationFailed() { lockBar.showError() }
                function onUnlockStarted() {
                    lockBar.unlocking = true
                    if (!root.nativeCanvas) login.playUnlock()
                }
            }
        }
    }

    Timer {
        id: unlockDelay
        interval: 650
        onTriggered: {
            sessionLock.locked = false
            Qt.quit()
        }
    }
}
