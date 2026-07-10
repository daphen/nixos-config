// The family keycap: raised chip, hairline ring, action-ink glyph.
// Identical recipe across the picker chins, app statusbars, and hint caps.
import QtQuick

Rectangle {
    property alias text: capText.text
    width: Math.max(capText.implicitWidth + 12, 22)
    height: 22
    radius: 7
    color: Theme.mode === "light" ? Theme.bg : Theme.surface2
    border.width: 1
    border.color: Theme.hairline
    Text {
        id: capText
        renderType: Text.NativeRendering
        anchors.centerIn: parent
        color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
        font.family: Theme.fontFamily
        font.hintingPreference: Font.PreferNoHinting
        font.pixelSize: 11
        font.weight: 500
    }
}
