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

    // tile_pos_in_workspace_view is already output-relative (it includes the
    // bar's exclusive-zone offset — verified: y=60 with the bar vs 16 bar-less),
    // so the dot maps straight into the output-filling panel with no extra offset.
    property real viewOriginX: 0
    property real viewOriginY: 0
    property int pillW: 28
    property int pillH: 5

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
        width: root.pillW
        height: root.pillH
        radius: height / 2
        color: Theme.cursor
        visible: root.geom !== null
        // Horizontally centered under the focused window; vertically centered in
        // the gap between the window's bottom edge and the output's bottom edge.
        x: root.geom ? root.viewOriginX + root.geom.x + root.geom.w / 2 - root.pillW / 2 : 0
        y: root.geom ? (root.viewOriginY + root.geom.y + root.geom.h + parent.height) / 2 - root.pillH / 2 : 0

        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
}
