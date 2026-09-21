import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQml
import "modules"

ShellRoot {
    id: root

    Process {
        id: themeFollower
        command: ["themectl-watch"]
        running: true
        stdout: SplitParser { onRead: data => console.log(data) }
        stderr: SplitParser { onRead: data => console.error(data) }
        onExited: (code, status) => {
            console.warn("Theme follower exited:", code, status);
            themeRestart.start();
        }
    }
    Timer {
        id: themeRestart
        interval: 2000
        onTriggered: themeFollower.running = true
    }

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

    Loader {
        active: Quickshell.env("HYPR_CANVAS_PROFILE") !== "deck"
        sourceComponent: CmdPalette {}
    }
    WpmBadge {}
}
