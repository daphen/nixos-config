import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Orange dot centered on the bottom edge of the focused window — a focus
// indicator that isn't a border. Positions itself from niri's IPC geometry
// (NiriState.focusedWindowGeom), which is only populated once the patched niri
// runs; until then the geometry is null and this stays hidden (dormant).
//
// For floating and fullscreen windows the pill slides off the bottom edge
// rather than vanishing — the same detach-on-fullscreen idea the notification
// island uses, played as motion instead of a cut.
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

    readonly property bool tileIsFullscreen: NiriState.focusedIsFullscreen(height)
    // Parked rather than hidden: the pill slides off the bottom edge so the
    // transition reads as motion, the way the notification island detaches
    // instead of popping. Toggling `visible` would cut the animation.
    readonly property bool parked: geom === null || geom.floating || tileIsFullscreen
    readonly property real parkedY: height + pillH * 2

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
        // Horizontally centered under the focused window; vertically centered in
        // the gap between the window's bottom edge and the output's bottom edge.
        x: root.geom ? root.viewOriginX + root.geom.x + root.geom.w / 2 - root.pillW / 2 : 0
        y: root.parked
            ? root.parkedY
            : (root.viewOriginY + root.geom.y + root.geom.h + parent.height) / 2 - root.pillH / 2

        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
}
