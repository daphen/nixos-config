import QtQuick
import "."
import "../QsLib" as Lib

// Open quick-todo count for the notch; hidden at zero. Click opens the
// todo picker (Super+Ctrl+Shift+T).
Item {
    id: root

    implicitWidth: row.implicitWidth + Theme.modulePadH * 2
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: TodoListPickerState.openCount > 0

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Lib.Icon {
            name: "clipboard-check"
            color: Theme.fg
            width: 15; height: 15
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: TodoListPickerState.openCount
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: TodoListPickerState.toggle()
    }
}
