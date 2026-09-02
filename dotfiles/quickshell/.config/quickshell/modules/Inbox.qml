import QtQuick
import Quickshell
import "."

Item {
    id: root

    property int _notifTick: 0
    Connections {
        target: Notifications.server
        function onTrackedNotificationsChanged() { root._notifTick++ }
    }

    readonly property int total: {
        const _ = root._notifTick
        const __ = Notifications.seenGen
        const focusedApp = Notifications.focusedApp
        const coveredApps = Notifications.focusedAppCovers[focusedApp] || []
        const model = Notifications.server ? Notifications.server.trackedNotifications : null
        const tracked = model ? model.values : []
        let count = 0
        for (let i = 0; i < tracked.length; i++) {
            const app = (tracked[i].appName || "").toLowerCase()
            if (Notifications.isTrayApp(tracked[i])
                    && !Notifications.isAiNotification(tracked[i])
                    && coveredApps.indexOf(app) === -1
                    && !Notifications.isSeen(tracked[i])) count++
        }
        return count
    }

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

            SequentialAnimation on opacity {
                running: root.total > 0
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 650; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
            }
        }
    }
}
