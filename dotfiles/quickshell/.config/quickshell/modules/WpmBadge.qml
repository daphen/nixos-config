import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Brief floating badge that pops when a typing burst crosses `threshold` wpm,
// tracks the burst's peak, then fades out. Same source as the bar pill
// (WpmState → wpm-daemon); this is just a transient, celebratory surface.
// Sits lower-center, clear of the cockpit notch (bottom:0) and the top island.
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
    property int peak: 0
    property bool open: false

    anchors.bottom: true
    margins.bottom: 160
    implicitWidth: 460
    implicitHeight: 120
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-wpm-badge"
    mask: Region {}
    visible: active

    property bool active: false

    Connections {
        target: WpmState
        function onValueChanged() {
            const v = WpmState.value
            if (v <= root.threshold) return
            if (v > root.peak) root.peak = v
            root.show()
        }
    }

    function show() {
        active = true
        open = true
        holdTimer.restart()
    }

    Timer { id: holdTimer; interval: 1600; onTriggered: root.open = false }
    Timer {
        id: closeDelay
        interval: 260
        onTriggered: { root.active = false; root.peak = 0 }
    }
    onOpenChanged: if (!open) closeDelay.restart()

    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.open ? (parent.height - height) / 2 : parent.height
        width: row.implicitWidth + Theme.notchPadH * 4
        height: 84
        color: Theme.notch
        radius: height / 2
        border.width: 1
        border.color: Theme.hairline
        opacity: root.open ? 1 : 0
        scale: root.open ? 1 : 0.9

        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 8

            Text {
                text: root.peak
                color: Theme.sky
                font.family: Theme.fontFamily
                font.pixelSize: 52
                font.weight: Font.Bold
                font.hintingPreference: Font.PreferFullHinting
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "wpm"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: 22
                font.weight: Theme.fontWeight
                font.hintingPreference: Font.PreferFullHinting
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
