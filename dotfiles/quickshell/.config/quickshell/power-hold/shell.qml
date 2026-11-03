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

    IpcHandler {
        target: "powerhold"
        function start() { root.armed = false; root.progress = 0; root.holding = true; reveal.restart(); fill.restart(); expire.restart() }
        function arm() { root.armed = true }
        function cancel() { root.holding = false; root.armed = false; reveal.stop(); fill.stop(); expire.stop() }
    }
    // Taps release well before this, so they never flash the hint.
    Timer { id: reveal; interval: 150 }
    NumberAnimation { id: fill; target: root; property: "progress"; from: 0; to: 1; duration: 4000 }
    // A cancel lost to a cold start must not strand the hint on screen.
    Timer { id: expire; interval: 8000; onTriggered: { root.holding = false; root.armed = false } }

    PanelWindow {
        visible: root.holding && !reveal.running
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "power-hold"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        anchors.bottom: true
        margins.bottom: 64
        implicitWidth: pill.width
        implicitHeight: pill.height
        mask: Region {}

        Lib.PillSurface {
            id: pill
            width: row.implicitWidth + 36; height: 48
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 12
                Canvas {
                    id: ring
                    width: 28; height: 28
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property real p: root.armed ? 1 : root.progress
                    onPChanged: requestPaint()
                    onPaint: {
                        const c = getContext("2d"), r = width / 2 - 1.5
                        c.clearRect(0, 0, width, height)
                        c.lineWidth = 2.5; c.lineCap = "round"
                        c.strokeStyle = Qt.alpha(Lib.Theme.fg, 0.18)
                        c.beginPath(); c.arc(width / 2, height / 2, r, 0, 2 * Math.PI); c.stroke()
                        c.strokeStyle = root.armed ? Lib.Theme.orange : Lib.Theme.fg
                        c.beginPath(); c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * p); c.stroke()
                    }
                    Lib.Icon {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        name: "pizza-slice-2"
                        color: root.armed ? Lib.Theme.orange : Lib.Theme.fg
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.armed ? "Release to suspend" : "Keep holding for 4s to suspend"
                    color: Lib.Theme.fg
                    font { family: Lib.Theme.fontFamily; pixelSize: Lib.Theme.fontSize + 2; weight: 600 }
                }
            }
        }
    }
}
