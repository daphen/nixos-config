import QtQuick
import QtQuick.Effects
import Quickshell
import "."

Item {
    id: root

    property int _notifTick: 0
    Connections {
        target: Notifications.server
        function onTrackedNotificationsChanged() { root._notifTick++ }
    }

    readonly property var inboxCounts: {
        const _ = root._notifTick
        const __ = Notifications.seenGen
        const ___ = Notifications.focusedApp   // re-evaluate when window focus changes
        const model = Notifications.server ? Notifications.server.trackedNotifications : null
        const tracked = model ? model.values : []
        const counts = { slack: 0, discord: 0, mail: 0 }
        for (let i = 0; i < tracked.length; i++) {
            if (Notifications.isSeen(tracked[i])) continue
            const app = (tracked[i].appName || "").toLowerCase()
            if (app === "slack") counts.slack++
            else if (app === "discord") counts.discord++
            else if (app === "mlqs") counts.mail++
        }
        // Don't badge the client you're focused on — you're already in it. The
        // toast still flashes and history is untouched; only the bar badge is hidden.
        const covers = Notifications.focusedAppCovers[Notifications.focusedApp] || []
        if (covers.indexOf("slack") !== -1) counts.slack = 0
        if (covers.indexOf("discord") !== -1) counts.discord = 0
        if (covers.indexOf("mlqs") !== -1) counts.mail = 0
        return counts
    }
    readonly property int total: inboxCounts.slack + inboxCounts.discord + inboxCounts.mail

    implicitWidth: visible ? row.implicitWidth + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: total > 0

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/inbox-jump"])
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 10

        Repeater {
            model: [
                { app: "slack",   count: root.inboxCounts.slack },
                { app: "discord", count: root.inboxCounts.discord },
                { app: "mlqs",    count: root.inboxCounts.mail }
            ]
            delegate: Row {
                required property var modelData
                visible: modelData.count > 0
                spacing: 4
                anchors.verticalCenter: parent.verticalCenter

                // brand glyphs (shared map with the island + super+i picker)
                Item {
                    width: 15; height: 15
                    anchors.verticalCenter: parent.verticalCenter
                    Image {
                        id: brand
                        anchors.fill: parent
                        source: Notifications.appIconFor(modelData.app)
                        sourceSize.width: 15; sourceSize.height: 15
                        visible: false
                        asynchronous: true
                    }
                    MultiEffect {
                        anchors.fill: brand
                        source: brand
                        colorization: 1
                        colorizationColor: Theme.cursor
                    }
                }
                Text {
                    visible: modelData.count > 1
                    text: modelData.count
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    font.weight: Theme.fontWeight
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
