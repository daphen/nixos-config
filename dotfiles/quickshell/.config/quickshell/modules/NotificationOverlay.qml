import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

PanelWindow {
    id: root

    // Follow the focused monitor without a binding loop: bind `screen` to the
    // focused output. `visible` never reads `screen`, so the two can't loop.
    screen: {
        const _ = NiriState.version
        const scrs = Quickshell.screens
        for (let i = 0; i < scrs.length; i++)
            if (scrs[i].name === NiriState.focusedOutput()) return scrs[i]
        return scrs.length ? scrs[0] : null
    }

    anchors {
        top: true
        right: true
    }

    margins.top: Theme.barHeight / 2
    margins.right: 16

    // Gated only on having notifications, NOT on the focused output. Flipping
    // this per-screen on focus changes churned the layer-shell window and
    // crashed quickshell 0.2.1 (it re-parented the toast across windows).
    visible: Notifications.tracked.values.length > 0

    implicitWidth: 380
    implicitHeight: Math.max(toastColumn.implicitHeight + 16, 1)
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-notifications"

    Column {
        id: toastColumn
        anchors {
            top: parent.top
            right: parent.right
            left: parent.left
            topMargin: 0
            leftMargin: 8
            rightMargin: 8
        }
        spacing: 8

        move: Transition {
            NumberAnimation { properties: "y"; duration: 150; easing.type: Easing.OutCubic }
        }

        Repeater {
            model: Notifications.tracked

            // Toast.qml owns the toast lifecycle: after its timeout it
            // collapses inbox-app toasts (slack/slk/endcord/kitty) while
            // keeping them tracked for the Super+i picker, and dismisses
            // others. No wrapper needed.
            Toast {
                required property var modelData
                notification: modelData
                width: 360
            }
        }
    }
}
