import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import "."

Rectangle {
    id: root

    required property var notification

    property bool shown: false
    property bool dismissing: false
    property bool collapsed: false

    // Report on-screen state (for Super+i's jump-to-lone-toast). The id is
    // captured up front — the Notification object may be gone at destruction.
    property int notifId: 0
    readonly property bool onScreen: shown && !dismissing && !collapsed
    onOnScreenChanged: Notifications.setToastVisible(notifId, onScreen)
    Component.onDestruction: Notifications.setToastVisible(notifId, false)

    opacity: (shown && !dismissing && !collapsed) ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

    // Never animate height: it propagates to the PanelWindow's
    // implicitHeight, and per-frame layer-shell resizes render at ~10fps.
    // Fade first, snap the height once fully invisible.
    height: (collapsed && opacity === 0) ? 0 : implicitHeight
    clip: true

    // Never flash a toast for one that's already seen (arrived while focused on
    // its source) or restored across a Quickshell reload (rebuild/theme switch).
    Component.onCompleted: { notifId = notification ? (notification.id || 0) : 0; shown = true; if (Notifications.isSeen(notification) || !Notifications.isLive(notification) || !Notifications.startupSettled) collapsed = true }

    Connections {
        target: Notifications
        function onSeenGenChanged() {
            if (Notifications.isSeen(root.notification)) root.collapsed = true
        }
    }

    function beginDismiss() {
        if (dismissing) return
        dismissing = true
    }

    Timer {
        id: dismissDelay
        running: root.dismissing
        interval: 220
        onTriggered: if (notification) notification.dismiss()
    }

    readonly property bool isCritical: notification && notification.urgency === NotificationUrgency.Critical
    readonly property real effectiveTimeout: {
        if (!notification) return 5000
        if (isCritical) return 30000
        const t = notification.expireTimeout
        if (t < 0) return 5000
        if (t === 0) return 5000
        return t
    }

    implicitWidth: 360
    implicitHeight: content.implicitHeight + 24

    color: Theme.notch
    radius: Theme.radius
    border.color: isCritical ? Theme.red : Theme.hairline
    border.width: 1

    Row {
        id: content
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: 12
        }
        spacing: 10

        // Sender avatar from the image-path hint (dsqrd). Hidden unless the
        // image actually loads, so other apps' toasts are unaffected.
        ClippingRectangle {
            id: avatar
            readonly property string src: {
                const p = root.notification ? (root.notification.image || "") : ""
                return p.startsWith("/") ? "file://" + p : p
            }
            visible: avatarImg.status === Image.Ready
            width: visible ? 40 : 0
            height: 40
            radius: width / 2
            color: "transparent"

            Image {
                id: avatarImg
                anchors.fill: parent
                source: avatar.src
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 80
                sourceSize.height: 80
                smooth: true
                cache: true
            }
        }

        Column {
            width: parent.width - (avatar.visible ? avatar.width + content.spacing : 0)
            spacing: 4

            Text {
                width: parent.width
                text: notification ? (notification.appName || "Notification") : ""
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                font.weight: Theme.fontWeight
                renderType: Text.NativeRendering
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: notification ? notification.summary : ""
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.weight: 600
                renderType: Text.NativeRendering
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 2
            }

            Text {
                width: parent.width
                visible: text.length > 0
                text: notification ? notification.body : ""
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
                font.weight: Theme.fontWeight
                renderType: Text.NativeRendering
                textFormat: Text.MarkdownText
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 5
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.beginDismiss()
    }

    Timer {
        running: effectiveTimeout > 0 && !root.dismissing && !root.collapsed
        interval: effectiveTimeout
        // Tray apps (Slack/Discord/Claude) collapse but stay tracked, so the
        // Super+i center keeps them as history. Everything else (screenshots,
        // system notifs) drops once its toast times out — never kept.
        onTriggered: {
            if (Notifications.isTrayApp(root.notification)) root.collapsed = true
            else root.beginDismiss()
        }
    }
}
