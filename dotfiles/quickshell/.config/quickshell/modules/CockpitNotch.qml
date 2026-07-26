import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Bottom-center notch that slides in when the focused workspace becomes the
// cockpit, shows which context is active, holds briefly, slides back out.
// Mirrors the top notch's shape (inverted corners) and the island's
// follow-the-focused-monitor pattern.
PanelWindow {
    id: root

    screen: {
        const _ = NiriState.version
        const scrs = Quickshell.screens
        for (let i = 0; i < scrs.length; i++)
            if (scrs[i].name === NiriState.focusedOutput()) return scrs[i]
        return scrs.length ? scrs[0] : null
    }

    anchors.bottom: true
    margins.bottom: 0
    implicitWidth: 600
    implicitHeight: Theme.barHeight + 34
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-cockpit-notch"
    mask: Region { item: capsule }
    visible: active

    property bool active: false
    property bool open: false
    property string _lastWs: ""

    readonly property var activeCtx: {
        for (const c of CockpitState.contexts)
            if (c.name === CockpitState.active) return c
        return null
    }

    // A context switch while already ON the cockpit workspace deserves the
    // badge too — active changes optimistically (picker/chips) and via the
    // state-file watch (scripts, Super+O, orchestrator), so both paths land here.
    Connections {
        target: CockpitState
        function onActiveChanged() {
            if (NiriState.focusedWorkspaceName() === CockpitState.workspace
                && root.activeCtx !== null)
                root.show()
        }
    }

    Connections {
        target: NiriState
        function onVersionChanged() {
            const ws = NiriState.focusedWorkspaceName()
            if (ws === root._lastWs) return
            root._lastWs = ws
            if (ws === CockpitState.workspace && root.activeCtx !== null)
                root.show()
            else
                root.hide()
        }
    }

    function show() {
        active = true
        open = true
        holdTimer.restart()
    }

    function hide() {
        open = false
        holdTimer.stop()
        closeDelay.restart()
    }

    Timer { id: holdTimer; interval: 1800; onTriggered: root.hide() }
    Timer { id: closeDelay; interval: 250; onTriggered: root.active = false }

    // Floating capsule — the island's detached (fullscreen) look, from the
    // bottom: fully rounded, hairline border, 8px off the edge.
    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.open ? parent.height - height - 8 : parent.height
        width: row.implicitWidth + Theme.notchPadH * 3
        height: Theme.barHeight + 14
        color: Theme.notch
        radius: Math.min(height / 2, Theme.notchRadius + 6)
        border.width: 1
        border.color: Theme.hairline

        Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 8

            Image {
                source: "file://" + Quickshell.env("HOME") + "/.local/share/icons/hicolor/512x512/apps/lovable.png"
                sourceSize.width: 20
                sourceSize.height: 20
                width: 20
                height: 20
                smooth: true
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.activeCtx ? root.activeCtx.name : ""
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 4
                font.weight: Theme.fontWeight
                font.hintingPreference: Font.PreferFullHinting
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: CockpitState.toggle()
        }
    }
}
