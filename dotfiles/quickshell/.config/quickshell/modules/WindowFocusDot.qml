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

    // One window follows the focused output, so on a monitor change the pill
    // keeps x/y from the PREVIOUS screen's coordinate space and then animates
    // diagonally to the new spot — entering from whatever corner the old
    // position happened to map to. Warp instead: snap (animation suppressed) to
    // parked, centred under the newly focused window, then slide up as usual.
    readonly property string outName: {
        const _ = NiriState.version
        return NiriState.focusedOutput()
    }
    property bool warping: false
    onOutNameChanged: { warping = true; warpEnd.restart() }
    Timer { id: warpEnd; interval: 32; onTriggered: root.warping = false }

    readonly property var geom: NiriState.focusedWindowGeom()

    // A focused layer-shell surface (any of the quickshell pickers) leaves niri
    // with ZERO focused windows, so geom goes null for as long as the picker is
    // up. Freeze on the last real geometry instead of reacting: otherwise the
    // pill animates to x=0 and parks, flying out to the left and back on every
    // picker open. Only a genuinely empty workspace should park it.
    property var lastGeom: null
    onGeomChanged: if (geom !== null) lastGeom = geom

    readonly property bool anyWindows: {
        const _ = NiriState.version
        for (const id in NiriState.windows) return true
        return false
    }
    readonly property var effGeom: geom !== null ? geom
                                                 : (anyWindows ? lastGeom : null)
    // Position off the last known box even while hidden, so returning from an
    // empty workspace fades back in place rather than sliding in from x=0.
    readonly property var posGeom: effGeom !== null ? effGeom : lastGeom

    // Tested against effGeom, not live focus: a picker opening over a fullscreen
    // window must not un-park the pill for as long as the picker holds focus.
    readonly property bool tileIsFullscreen: NiriState.isFullscreenGeom(effGeom, height)
    // Parked rather than hidden: the pill slides off the bottom edge so the
    // transition reads as motion, the way the notification island detaches
    // instead of popping. Toggling `visible` would cut the animation.
    readonly property bool parked: effGeom === null || effGeom.floating || tileIsFullscreen
    readonly property real parkedY: height + pillH * 2

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-window-focus-dot"
    mask: Region {}
    visible: effGeom !== null

    Rectangle {
        id: dot
        width: root.pillW
        height: root.pillH
        radius: height / 2
        color: Theme.cursor
        // Horizontally centered under the focused window; vertically centered in
        // the gap between the window's bottom edge and the output's bottom edge.
        // Holds its x when geometry is momentarily absent, so a picker opening
        // never drags the pill sideways.
        x: root.posGeom ? root.viewOriginX + root.posGeom.x + root.posGeom.w / 2 - root.pillW / 2 : 0
        // Warping counts as parked, so a monitor change lands below the bottom
        // edge — already centred on the new x, since x snaps with animation off.
        y: root.warping || root.parked || !root.posGeom
            ? root.parkedY
            : (root.viewOriginY + root.posGeom.y + root.posGeom.h + parent.height) / 2 - root.pillH / 2

        // Suppressed during a warp so the reposition is instantaneous; the slide
        // up then plays from the bottom edge once warping clears.
        Behavior on x { enabled: !root.warping; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: !root.warping; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
}
