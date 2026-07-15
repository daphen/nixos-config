import QtQuick
import Quickshell
import "."
import "../QsLib" as Lib

Item {
    id: root

    // dangling `text` ref (the old Text badge) made this 0px wide — DND could
    // be active with no visible trace in the bar
    implicitWidth: visible ? icon.width + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: DndState.active

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: DndState.toggle()
    }

    Lib.Icon {
        id: icon
        name: "bell-slash"
        color: Theme.cursor
        width: 15; height: 15
        anchors.centerIn: parent
    }
}
