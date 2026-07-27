import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Orange dot centered on the bottom edge of the focused window — a focus
// indicator that isn't a border. Positions itself from niri's IPC geometry
// (NiriState.focusedWindowGeom), which is only populated once the patched niri
// runs; until then the geometry is null and this stays hidden (dormant).
//
// PLACEMENT IS PROVISIONAL: viewOriginY (the workspace-view top offset below
// the bar) is a first guess and needs one tuning pass against the live patched
// niri before this is trustworthy.
PanelWindow {
    id: root

    screen: {
        const _ = NiriState.version
        const scrs = Quickshell.screens
        for (let i = 0; i < scrs.length; i++)
            if (scrs[i].name === NiriState.focusedOutput()) return scrs[i]
        return scrs.length ? scrs[0] : null
    }

    // Workspace-view origin within the output. niri's view sits below the top
    // bar; x is flush left. TUNE against live niri.
    property real viewOriginX: 0
    property real viewOriginY: Theme.barHeight
    property int dotSize: 8

    readonly property var geom: NiriState.focusedWindowGeom()

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-window-focus-dot"
    mask: Region {}
    visible: geom !== null

    Rectangle {
        id: dot
        width: root.dotSize
        height: root.dotSize
        radius: width / 2
        color: "#ff8800"
        visible: root.geom !== null
        x: root.geom ? root.viewOriginX + root.geom.x + root.geom.w / 2 - width / 2 : 0
        y: root.geom ? root.viewOriginY + root.geom.y + root.geom.h - height / 2 : 0

        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
}
