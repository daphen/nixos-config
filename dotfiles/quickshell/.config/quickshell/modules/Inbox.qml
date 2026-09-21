import QtQuick
import Quickshell
import "."

Item {
    id: root

    readonly property int total: NotificationJumpPickerState.total
    readonly property bool needsAttention: NotificationJumpPickerState.needsAttention

    implicitWidth: visible ? marker.width + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: total > 0

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/inbox-jump"])
    }

    Item {
        id: marker
        anchors.centerIn: parent
        width: 16
        height: 16

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.surface2
        }

        Rectangle {
            id: dot
            anchors.centerIn: parent
            width: 8
            height: 8
            radius: width / 2
            color: Theme.cursor
            opacity: root.needsAttention ? pulseOpacity : 0.35
            property real pulseOpacity: 1

            SequentialAnimation on pulseOpacity {
                running: root.needsAttention
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 650; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
            }
        }
    }
}
