import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick.Effects
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
        // Freeze the last frame so the fade-out shows what was on screen, not a reset.
        function cancel() { root.holding = false; reveal.stop(); fill.stop(); expire.stop() }
    }
    // Taps release well before this, so they never flash the hint.
    Timer { id: reveal; interval: 400 }
    NumberAnimation { id: fill; target: root; property: "progress"; from: 0; to: 1; duration: 3000 }
    // A cancel lost to a cold start must not strand the hint on screen.
    Timer { id: expire; interval: 8000; onTriggered: root.holding = false }

    PanelWindow {
        visible: content.vis > 0
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
            property real vis: root.shown ? 1 : 0
            Behavior on vis { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            opacity: vis

            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.62) }

            Column {
                anchors.centerIn: parent
                spacing: 28
                scale: 0.96 + 0.04 * content.vis
                layer.enabled: content.vis < 1
                layer.effect: MultiEffect { blurEnabled: true; blurMax: 32; blur: 1 - content.vis }

                Lib.ContextMeter {
                    id: meter
                    width: 460; height: 40
                    anchors.horizontalCenter: parent.horizontalCenter
                    fieldMargin: 4
                    fillDuration: 0
                    percent: (root.armed ? 1 : root.progress) * 100
                }
                Lib.Crossfade {
                    id: title
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(holdText.implicitWidth, releaseText.implicitWidth); height: holdText.implicitHeight
                    showSecond: root.armed
                    enterDuration: 260; exitDuration: 200
                    shift: 6; blurAmount: 0.5
                    first: Text {
                        id: holdText
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Keep holding for 3s to suspend"
                        color: "#FAFAFA"
                        font { family: Lib.Theme.fontFamily; pixelSize: Lib.Theme.fontSize * 2; weight: 600 }
                    }
                    second: Text {
                        id: releaseText
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Release to suspend"
                        color: meter.ink
                        font: holdText.font
                    }
                }
                Lib.Crossfade {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: hintText.implicitWidth; height: hintText.implicitHeight
                    showSecond: root.armed
                    enterDuration: 260; exitDuration: 200
                    shift: 6; blurAmount: 0.5
                    first: Text {
                        id: hintText
                        text: "Let go to cancel"
                        color: Qt.alpha("#FAFAFA", 0.55)
                        font { family: Lib.Theme.fontFamily; pixelSize: Lib.Theme.fontSize + 4 }
                    }
                }
            }
        }
    }
}
