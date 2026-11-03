import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QsLib as Lib

// Deck power-key hold hint, driven by the Hyprland bind: start on press, armed at the threshold, cancel on release.
ShellRoot {
    id: root
    property bool holding: false
    property bool armed: false
    property real progress: 0
    readonly property bool shown: holding && !reveal.running

    IpcHandler {
        target: "powerhold"
        function start() { root.armed = false; root.progress = 0; root.holding = true; reveal.restart(); fill.restart(); expire.restart() }
        function arm() { root.armed = true }
        function cancel() { root.holding = false; root.armed = false; reveal.stop(); fill.stop(); expire.stop() }
    }
    // Taps release well before this, so they never flash the hint.
    Timer { id: reveal; interval: 400 }
    NumberAnimation { id: fill; target: root; property: "progress"; from: 0; to: 1; duration: 3000 }
    // A cancel lost to a cold start must not strand the hint on screen.
    Timer { id: expire; interval: 8000; onTriggered: { root.holding = false; root.armed = false } }

    PanelWindow {
        visible: root.shown || content.opacity > 0
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "power-hold"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        mask: Region {}

        Item {
            id: content
            anchors.fill: parent
            opacity: root.shown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.62) }

            Column {
                anchors.centerIn: parent
                spacing: 28
                scale: root.shown ? 1 : 0.92
                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }

                Lib.ContextMeter {
                    id: meter
                    width: 460; height: 40
                    anchors.horizontalCenter: parent.horizontalCenter
                    fieldMargin: 4
                    fillDuration: 0
                    percent: (root.armed ? 1 : root.progress) * 100
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.armed ? "Release to suspend" : "Keep holding for 3s to suspend"
                    color: root.armed ? meter.ink : "#FAFAFA"
                    font { family: Lib.Theme.fontFamily; pixelSize: Lib.Theme.fontSize * 2; weight: 600 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.armed ? "" : "Let go to cancel"
                    color: Qt.alpha("#FAFAFA", 0.55)
                    font { family: Lib.Theme.fontFamily; pixelSize: Lib.Theme.fontSize + 4 }
                }
            }
        }
    }
}
