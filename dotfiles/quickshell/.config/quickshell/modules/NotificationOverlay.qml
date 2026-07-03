import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

PanelWindow {
    id: root

    // Pin to one monitor (the output focused at startup), set imperatively so
    // it never re-anchors on focus change — moving a layer-shell window between
    // monitors crashes quickshell 0.2.1. True follow-focus needs a newer quickshell.
    Component.onCompleted: {
        const scrs = Quickshell.screens
        for (let i = 0; i < scrs.length; i++)
            if (scrs[i].name === NiriState.focusedOutput()) { screen = scrs[i]; return }
        if (scrs.length) screen = scrs[0]
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
