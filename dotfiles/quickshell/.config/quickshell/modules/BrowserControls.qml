import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Floating back / forward / reload pill for the focused Helium window; hovering
// its palette button opens CmdPalette, which cuts this pill out of its input mask.
PanelWindow {
    id: root

    readonly property int pillWidth: 172
    readonly property int pillHeight: 44
    readonly property int pillMargin: 16

    readonly property string profile: {
        const _ = NiriState.version
        if (!root.screen || NiriState.focusedOutput() !== root.screen.name) return ""
        if (NiriState.outputIsFullscreen(root.screen.name, root.screen.height)) return ""
        const app = NiriState.focusedAppId()
        return app === "browser-personal" ? "personal" : app === "browser-work" ? "work" : ""
    }

    // Mapping and unmapping a blurred layer mid-navigation makes the canvas stutter,
    // so the surface stays mapped and only its content fades.
    mask: Region { item: root.profile !== "" ? pill : null }
    anchors.bottom: true
    margins.bottom: pillMargin
    implicitWidth: pillWidth
    implicitHeight: pillHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-browser-controls"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    function shortcut(mods, key) {
        Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.send_shortcut({ mods = \"" + mods + "\", key = \"" + key + "\" })"])
    }

    Rectangle {
        id: pill
        anchors.fill: parent
        opacity: root.profile !== "" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
        radius: height / 2
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.55)
        border.width: 1
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.12)

        Row {
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: [
                    { glyph: "←", act: () => root.shortcut("ALT", "Left") },
                    { glyph: "→", act: () => root.shortcut("ALT", "Right") },
                    { glyph: "↻", act: () => root.shortcut("", "F5") },
                    { glyph: "⌕", palette: true },
                ]

                Item {
                    required property var modelData
                    width: 36
                    height: 36

                    Rectangle {
                        anchors.fill: parent
                        radius: 9
                        color: hover.hovered ? Theme.itemHover : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: modelData.glyph
                            color: hover.hovered ? Theme.fg : Theme.fg_muted
                            font.family: Theme.fontFamily
                            font.pixelSize: 18
                        }
                    }
                    HoverHandler {
                        id: hover
                        cursorShape: Qt.PointingHandCursor
                        onHoveredChanged: {
                            if (!modelData.palette) return
                            if (hovered && !PaletteState.open) dwell.restart()
                            else dwell.stop()
                        }
                    }
                    TapHandler {
                        onTapped: modelData.palette ? root.openPalette() : modelData.act()
                    }
                    Timer {
                        id: dwell
                        interval: 175
                        onTriggered: if (hover.hovered) root.openPalette()
                    }
                }
            }
        }
    }

    function openPalette() {
        if (PaletteState.open || profile === "") return
        PaletteState.targetOutput = root.screen.name
        PaletteState.focusProfile(profile)
        PaletteState.show()
    }
}
