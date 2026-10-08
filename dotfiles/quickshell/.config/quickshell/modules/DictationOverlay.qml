import QtQuick
import Quickshell
import Quickshell.Wayland
import QsLib as Lib
import "."

PanelWindow {
    id: root

    property bool mapped: DictationState.active

    screen: {
        const _ = NiriState.version
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++)
            if (screens[i].name === NiriState.focusedOutput()) return screens[i]
        return screens.length ? screens[0] : null
    }

    anchors.bottom: true
    margins.bottom: 44
    implicitWidth: 160
    implicitHeight: 160
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-dictation"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}
    visible: mapped

    Connections {
        target: DictationState
        function onActiveChanged() {
            if (DictationState.active) {
                closeDelay.stop()
                root.mapped = true
            } else {
                closeDelay.restart()
            }
        }
    }

    Timer {
        id: closeDelay
        interval: 280
        onTriggered: root.mapped = false
    }

    // Speech RMS sits low on a linear scale; sqrt spreads it so normal talking moves the orb.
    property real voice: Math.min(1, Math.sqrt(DictationState.level) * 1.6)
    Behavior on voice { SmoothedAnimation { velocity: 4 } }

    Lib.ThinkingOrb {
        anchors.centerIn: parent
        width: 112
        height: 112
        running: DictationState.active
        glow: DictationState.processing ? Lib.Theme.electric : Lib.Theme.orange
        seedKey: "voice-dictation"
        flow: DictationState.processing ? 4.5 : 3.5
        warp: 1.5 + root.voice * 1.6
        bright: 0.55 + root.voice * 0.3
        plasma: 0.05 + root.voice * 0.25
        swirl: 1.2 + root.voice
        transform: Scale {
            origin.x: 56
            origin.y: 56
            xScale: 1 + root.voice * 0.18
            yScale: xScale
        }
    }
}
