import QtQuick
import QtQuick.Shapes
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

    // Measured speech RMS: ~0.005 silence, 0.015-0.10 talking; normalize that band, curve keeps quiet syllables visible.
    readonly property real voiceTarget: DictationState.recording
        ? Math.pow(Math.max(0, Math.min(1, (DictationState.level - 0.008) / 0.07)), 0.7)
        : 0
    property real voice: 0
    // Fast attack, slow release: syllables kick the orb, pauses let it settle.
    FrameAnimation {
        running: root.mapped && (root.voiceTarget > 0 || root.voice > 0.002)
        onTriggered: {
            const tau = root.voiceTarget > root.voice ? 0.05 : 0.38
            root.voice += (root.voiceTarget - root.voice) * (1 - Math.exp(-frameTime / tau))
        }
    }

    readonly property color orbGlow: DictationState.processing ? Lib.Theme.electric : Lib.Theme.orange

    Shape {
        anchors.centerIn: parent
        width: 112
        height: 112
        scale: 1.04 + root.voice * 0.34
        opacity: DictationState.active ? 0.18 + root.voice * 0.5 : 0
        preferredRendererType: Shape.CurveRenderer
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: 56; centerY: 56; centerRadius: 56
                focalX: 56; focalY: 56
                GradientStop { position: 0.55; color: Qt.alpha(root.orbGlow, 0.9) }
                GradientStop { position: 1.0; color: Qt.alpha(root.orbGlow, 0) }
            }
            PathAngleArc { centerX: 56; centerY: 56; radiusX: 56; radiusY: 56; sweepAngle: 360 }
        }
    }

    Lib.ThinkingOrb {
        anchors.centerIn: parent
        width: 112
        height: 112
        running: DictationState.active
        glow: root.orbGlow
        seedKey: "voice-dictation"
        flow: DictationState.processing ? 4.5 : 3.5
        warp: 1.5 + root.voice * 0.8
        bright: 0.55 + root.voice * 0.3
        plasma: 0.05 + root.voice * 0.12
        transform: Scale {
            origin.x: 56
            origin.y: 56
            xScale: 1 + root.voice * 0.12
            yScale: xScale
        }
    }
}
