import QtQuick
import "."

// One compact chip per cockpit context: active is underlined, a context whose
// agent wants you turns accent. Colour only — no pulse, no fade; the cockpit
// surface never animates.
Row {
    id: root

    spacing: 6
    visible: CockpitState.contexts.length > 0

    Repeater {
        model: CockpitState.contexts

        Item {
            required property var modelData
            readonly property bool isActive: modelData.name === CockpitState.active

            width: chipLabel.implicitWidth + Theme.modulePadH * 2
            height: parent.height

            Text {
                id: chipLabel
                anchors.centerIn: parent
                text: modelData.name
                color: modelData.state === "awaiting-you" ? Theme.cursor
                     : parent.isActive ? Theme.fg
                     : Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.weight: Theme.fontWeight
                font.hintingPreference: Font.PreferFullHinting
            }

            Rectangle {
                anchors.horizontalCenter: chipLabel.horizontalCenter
                anchors.top: chipLabel.bottom
                anchors.topMargin: 2
                width: chipLabel.implicitWidth
                height: 1
                visible: parent.isActive
                color: chipLabel.color
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: CockpitState.switchTo(modelData.name)
            }
        }
    }
}
