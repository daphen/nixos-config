import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQml
import "modules"

ShellRoot {
    id: root

    // Per-screen surfaces — Variants reconciles when monitors come and
    // go, so undocking doesn't leave an orphan layer-shell window from
    // the disconnected screen (which niri then framed as a regular
    // toplevel with an empty transparent body).
    Variants {
        model: Quickshell.screens

        Scope {
            required property var modelData

            RoundedBar {
                id: bar
                screen: modelData
            }

            PanelWindow {
                screen: modelData
                visible: bar.pickerActive
                anchors { top: true; bottom: true; left: true; right: true }
                exclusiveZone: 0
                exclusionMode: ExclusionMode.Ignore
                color: "transparent"
                WlrLayershell.namespace: "qs-picker-dismiss"
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                mask: Region { item: dismissArea }

                MouseArea {
                    id: dismissArea
                    anchors.fill: parent
                    onClicked: bar.dismissPickers()
                }
            }
        }
    }

    // Dynamic-island notification capsule under the bar notch.
    NotificationIsland {}

    CmdPalette {}
    WpmBadge {}
}
