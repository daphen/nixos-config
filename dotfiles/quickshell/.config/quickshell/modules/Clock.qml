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
            name: "clock"
            color: Theme.fg
            width: 15; height: 15
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Qt.formatDateTime(clock.date, "HH:mm")
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            renderType: Text.NativeRendering
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
