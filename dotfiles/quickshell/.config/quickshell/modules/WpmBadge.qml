import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Small bottom-right badge showing the peak WPM of a completed typing burst.
// Driven by WpmState.burstNonce, which the daemon bumps only once typing has
// actually paused (>= its PAUSE_THRESHOLD), so it never appears mid-sentence.
// Styled like the notch — notch surface, hairline, pill radius, restrained type.
PanelWindow {
    id: root

    screen: {
        const _ = NiriState.version
        const scrs = Quickshell.screens
        for (let i = 0; i < scrs.length; i++)
            if (scrs[i].name === NiriState.focusedOutput()) return scrs[i]
        return scrs.length ? scrs[0] : null
    }

    property int threshold: 100
    property int shown: 0
    property bool open: false
    property bool active: false

    anchors { bottom: true; right: true }
    margins.bottom: 24
    margins.right: 24
    implicitWidth: 200
    implicitHeight: 80
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-wpm-badge"
    mask: Region {}
    visible: active

    Connections {
        target: WpmState
        function onBurstNonceChanged() {
            if (WpmState.burstPeak <= root.threshold) return
            root.shown = WpmState.burstPeak
            root.show()
        }
    }

    function show() {
        active = true
        open = true
        holdTimer.restart()
    }

    Timer { id: holdTimer; interval: 2200; onTriggered: root.open = false }
    Timer { id: closeDelay; interval: 260; onTriggered: root.active = false }
    onOpenChanged: if (!open) closeDelay.restart()

    Rectangle {
        id: capsule
        anchors.right: parent.right
        y: root.open ? parent.height - height : parent.height
        width: row.implicitWidth + Theme.notchPadH * 3
        height: Theme.barHeight
        color: Theme.notch
        radius: height / 2
        border.width: 1
        border.color: Theme.hairline
        opacity: root.open ? 1 : 0

        Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 6

            Text {
                text: root.shown
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 4
                font.weight: 700
                font.hintingPreference: Font.PreferFullHinting
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "wpm"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
                font.weight: Theme.fontWeight
                font.hintingPreference: Font.PreferFullHinting
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
