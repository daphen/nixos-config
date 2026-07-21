import QtQuick
import Quickshell
import "."
import "../QsLib" as Lib

Item {
    id: root

    implicitWidth: row.implicitWidth + Theme.modulePadH * 2
    implicitHeight: parent ? parent.height : Theme.barHeight

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Lib.Icon {
            name: "calendar-days"
            color: Theme.fg
            // airy line-glyph: +1px optical compensation vs solid neighbors
            width: 16; height: 16
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Qt.formatDateTime(clock.date, "ddd MMM dd")
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Hours
    }
}
