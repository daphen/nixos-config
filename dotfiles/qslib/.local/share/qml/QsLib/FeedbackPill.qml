// The family feedback pill ("Opening media…", "trashed — u undoes"):
// inverted ink chip, hairline ring, pulsing accent dot. Call show(text)
// for a transient toast or bind `active` for a persistent state.
import QtQuick

Rectangle {
    id: pill
    property alias text: label.text
    property bool active: false          // persistent mode (overrides timer)
    function show(msg) { label.text = msg; opacity = 1; hide.restart() }

    z: 201
    visible: opacity > 0
    opacity: active ? 1 : 0
    width: row.implicitWidth + 28
    height: 32
    radius: 8
    color: "transparent"
    border.width: 0
    Behavior on opacity { NumberAnimation { duration: Motion.base } }

    ContrastSurface { anchors.fill: parent; radius: pill.radius }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8
        Rectangle {
            width: 8; height: 8; radius: 4
            color: Theme.cursor
            anchors.verticalCenter: parent.verticalCenter
            readonly property real pulsePhase: (OrbClock.now % (Motion.pulse * 2)) / (Motion.pulse * 2)
            opacity: pill.visible ? 0.625 + 0.375 * Math.cos(pulsePhase * 2 * Math.PI) : 1
        }
        Text {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.onContrast
            font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 13
        }
    }
    Timer { id: hide; interval: 3000; onTriggered: if (!pill.active) pill.opacity = 0 }
}
