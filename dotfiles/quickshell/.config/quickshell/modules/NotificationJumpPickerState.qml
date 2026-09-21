pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "."

Singleton {
    id: root

    property bool open: false
    property alias viewedThroughId: persisted.viewedThroughId
    property int _notifTick: 0

    readonly property var pending: {
        const _ = root._notifTick
        const __ = Notifications.seenGen
        const focusedApp = Notifications.focusedApp
        const coveredApps = Notifications.focusedAppCovers[focusedApp] || []
        const model = Notifications.server ? Notifications.server.trackedNotifications : null
        const tracked = model ? model.values : []
        return tracked.filter(n => {
            const app = (n.appName || "").toLowerCase()
            return Notifications.isTrayApp(n)
                && !Notifications.isAiNotification(n)
                && coveredApps.indexOf(app) === -1
                && !Notifications.isSeen(n)
        })
    }
    readonly property int total: pending.length
    readonly property real latestId: {
        let latest = 0
        for (const n of pending) latest = Math.max(latest, Number(n.id) || 0)
        return latest
    }
    readonly property bool needsAttention: total > 0 && latestId > viewedThroughId

    Connections {
        target: Notifications.server
        function onTrackedNotificationsChanged() {
            root._notifTick++
            if (root.open) Qt.callLater(() => root.markViewed(root.latestId))
        }
    }

    PersistentProperties {
        id: persisted
        reloadableId: "notificationIndicator"
        property real viewedThroughId: 0
    }

    function markViewed(id) {
        viewedThroughId = Math.max(viewedThroughId, Number(id) || 0)
    }

    onOpenChanged: {
        if (open) markViewed(latestId)
    }

    // Fired by `showOrJump`; NotificationJumpPicker decides: exactly one toast
    // on screen → jump straight to it, else open the picker.
    signal jumpRequested()

    function toggle() { open = !open }
    function show()   { open = true }
    function hide()   { open = false }

    IpcHandler {
        target: "notification-jump"
        function toggle() { root.toggle() }
        function show()   { root.show() }
        function hide()   { root.hide() }
        function showOrJump() { root.jumpRequested() }
    }
}
