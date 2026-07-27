import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Transient badge celebrating a fast typing burst. Same source as the bar
// pill (WpmState → wpm-daemon). It stays silent WHILE typing: the peak is
// tracked in the background and only revealed once the value goes quiet
// (typing paused), so it never flashes mid-sentence. Styled like the notch
// island — notch surface, hairline border, pill radius, restrained type.
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
    property int peak: 0     // running max of the in-progress burst (silent)
    property int shown: 0    // frozen value currently on display
    property bool open: false
    property bool active: false

    anchors.bottom: true
    margins.bottom: 130
    implicitWidth: 320
    implicitHeight: 96
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-wpm-badge"
    mask: Region {}
    visible: active

    Connections {
        target: WpmState
        function onValueChanged() {
            const v = WpmState.value
            if (v <= root.threshold) return
            if (v > root.peak) root.peak = v
            settleTimer.restart()   // hold off until the burst goes quiet
        }
    }

    // Fires only after the value has been stable for the pause window — i.e.
    // typing has stopped. That is the moment to reveal the burst's peak.
    Timer { id: settleTimer; interval: 1400; onTriggered: root.reveal() }
    Timer { id: holdTimer; interval: 2200; onTriggered: root.open = false }
    Timer { id: closeDelay; interval: 260; onTriggered: root.active = false }
    onOpenChanged: if (!open) closeDelay.restart()

    function reveal() {
        if (root.peak <= root.threshold) return
        shown = peak
        peak = 0
        active = true
        open = true
        holdTimer.restart()
    }

    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.open ? (parent.height - height) / 2 : parent.height - height + 6
        width: row.implicitWidth + Theme.notchPadH * 3
        height: Theme.barHeight + 14
        color: Theme.notch
        radius: height / 2
        border.width: 1
        border.color: Theme.hairline
        opacity: root.open ? 1 : 0

        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 6

            Text {
                text: root.shown
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 6
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
