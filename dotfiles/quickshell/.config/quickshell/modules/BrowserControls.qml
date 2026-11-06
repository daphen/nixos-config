import QtQuick
import Quickshell
import Quickshell.Wayland
import "."
import "../QsLib" as Lib

// Back / forward / reload (bottom right) and a palette trigger (bottom centre) for
// the focused Helium window; each slides up only while the pointer is near it.
// Placed on the focused window using the canvas camera.
// CmdPalette cuts triggerZone out of its input mask so opening it cannot re-trigger.
PanelWindow {
    id: root

    readonly property int button: 36
    readonly property int pad: 4
    readonly property int reach: 16
    readonly property int pieceHeight: button + 2 * pad
    readonly property int inset: 16
    readonly property int edge: 12
    readonly property var win: {
        const _ = NiriState.version
        return NiriState.focusedScreenRect(root.screen ? root.screen.name : "", root.width, root.screen ? root.screen.height : 0)
    }
    readonly property real below: Math.max(0, (root.screen ? root.screen.height : 0) - win.y - win.h)

    readonly property string profile: {
        const _ = NiriState.version
        if (!root.screen || NiriState.focusedOutput() !== root.screen.name) return ""
        if (NiriState.outputIsFullscreen(root.screen.name, root.screen.height) || root.win.overview) return ""
        const app = NiriState.focusedAppId()
        return app === "browser-personal" ? "personal" : app === "browser-work" ? "work" : ""
    }

    // Mapping and unmapping a blurred layer mid-navigation makes the canvas stutter,
    // so the surface stays mapped and only its content fades.
    mask: Region {
        Region { item: root.profile !== "" ? navZone : null }
        Region { item: root.profile !== "" ? triggerZone : null }
    }
    anchors { bottom: true; left: true; right: true }
    implicitHeight: below + pieceHeight + inset + reach
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-browser-controls"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    function shortcut(mods, key) {
        Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.send_shortcut({ mods = \"" + mods + "\", key = \"" + key + "\" })"])
    }

    function openPalette() {
        if (PaletteState.open || profile === "") return
        PaletteState.targetOutput = root.screen.name
        PaletteState.focusProfile(profile)
        PaletteState.show()
    }

    component Piece: Rectangle {
        property bool near: false
        anchors.bottom: parent.bottom
        anchors.bottomMargin: near && root.profile !== "" ? root.inset : -height
        Behavior on anchors.bottomMargin {
            NumberAnimation {
                duration: Lib.Motion.slow
                easing.type: Lib.Motion.easeEmphasized
                easing.bezierCurve: Lib.Motion.curveEmphasized
            }
        }
        height: root.pieceHeight
        radius: height / 2
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.55)
        border.width: 1
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.12)
    }

    component Glyph: Item {
        id: glyph
        property string icon
        signal activated
        signal dwelled
        width: root.button
        height: root.button
        Rectangle {
            anchors.fill: parent
            radius: root.pieceHeight / 2 - root.pad
            color: hover.hovered ? Theme.itemHover : "transparent"
            Lib.Icon {
                anchors.centerIn: parent
                width: 18
                height: 18
                name: glyph.icon
                color: hover.hovered ? Theme.fg : Theme.fg_muted
            }
        }
        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: hovered && !PaletteState.open ? dwell.restart() : dwell.stop()
        }
        TapHandler { onTapped: glyph.activated() }
        Timer {
            id: dwell
            interval: 175
            onTriggered: if (hover.hovered) glyph.dwelled()
        }
    }

    // The window's bottom band; pieces rise out of the window's own bottom edge.
    Item {
        id: band
        x: root.win.x
        width: root.win.w
        anchors { bottom: parent.bottom; bottomMargin: root.below }
        height: root.pieceHeight + root.inset + root.reach
        clip: true

        Item {
            id: navZone
            anchors { right: parent.right; bottom: parent.bottom }
            width: nav.width + root.reach + root.inset
            height: parent.height
            HoverHandler { id: navNear }

            Piece {
                id: nav
                near: navNear.hovered
                anchors { right: parent.right; rightMargin: root.inset }
                width: navRow.width + 2 * root.pad
                Row {
                    id: navRow
                    anchors.centerIn: parent
                    spacing: 4
                    Glyph { icon: "chevron-left"; onActivated: root.shortcut("ALT", "Left") }
                    Glyph { icon: "chevron-right"; onActivated: root.shortcut("ALT", "Right") }
                    Glyph { icon: "refresh-2"; onActivated: root.shortcut("", "F5") }
                }
            }
        }

        Item {
            id: triggerZone
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom }
            width: root.pieceHeight + 2 * root.reach
            // Wakes only at the window's edge, then grows so the risen pill stays hovered.
            height: triggerNear.hovered ? parent.height : root.edge
            HoverHandler { id: triggerNear }

            Piece {
                near: triggerNear.hovered
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.pieceHeight
                Glyph {
                    anchors.centerIn: parent
                    icon: "grid-circle-plus"
                    onActivated: root.openPalette()
                    onDwelled: root.openPalette()
                }
            }
        }
    }
}
