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

    Lib.ThinkingOrb {
        anchors.centerIn: parent
        width: 112
        height: 112
        running: DictationState.active
        glow: DictationState.processing ? Lib.Theme.electric : Lib.Theme.orange
        seedKey: "voice-dictation"
        flow: DictationState.processing ? 4.5 : 3.5
    }
}
