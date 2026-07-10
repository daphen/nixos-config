import QtQuick
import Quickshell
import "."
import "../QsLib" as Lib

Item {
    id: root

    implicitWidth: visible ? text.implicitWidth + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: DndState.active

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: DndState.toggle()
    }

    Lib.Icon {
        name: "bell"
        color: Theme.cursor
        width: 15; height: 15
        anchors.verticalCenter: parent.verticalCenter
    }
}
