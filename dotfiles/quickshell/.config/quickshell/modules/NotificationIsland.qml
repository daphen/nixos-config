import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "."

// Dynamic-island notification capsule. Springs down out of the bar's
// centered notch when a notification arrives (Notifications.present),
// holds a few seconds, springs back. Click = the same activation the
// Super+i picker does (open channel / focus window). Coexists with the
// corner toasts for now — trial period before it replaces them.
PanelWindow {
    id: root

    // Follow the focused monitor — same pattern as NotificationOverlay
    // (safe on quickshell 0.3.0+).
    screen: {
        const _ = NiriState.version
        const scrs = Quickshell.screens
        for (let i = 0; i < scrs.length; i++)
            if (scrs[i].name === NiriState.focusedOutput()) return scrs[i]
        return scrs.length ? scrs[0] : null
    }

    // Sits just below the bar, horizontally centered (no side anchors →
    // niri centers the surface, which is also the notch's center).
    anchors.top: true
    margins.top: Theme.barHeight
    implicitWidth: 600
    implicitHeight: 120
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-island"
    // Input only over the capsule — the rest of the surface passes clicks
    // through to whatever is beneath.
    mask: Region { item: capsule }
    visible: active

    property bool active: false
    property bool open: false

    // Current presentation.
    property var notif: null           // live Notification (may die under us)
    property string nApp: ""
    property string nSummary: ""
    property string nBody: ""
    property string nImage: ""
    property string nWindowId: ""
    property int extraCount: 0         // arrivals that replaced content this show

    Connections {
        target: Notifications
        function onPresent(n) { root.show(n) }
    }

    function show(n) {
        const wasOpen = open
        notif = n
        nApp = n.appName || ""
        nSummary = n.summary || ""
        nBody = (n.body || "").replace(/<[^>]+>/g, "").replace(/\n/g, "  ")
        const img = n.image || ""
        nImage = img ? (img.startsWith("/") ? "file://" + img : img) : ""
        nWindowId = (n.hints && n.hints["niri-window"] !== undefined)
            ? String(n.hints["niri-window"]) : ""
        extraCount = wasOpen ? extraCount + 1 : 0
        closeDelay.stop()
        active = true
        open = true
        holdTimer.restart()
    }

    function hide() {
        open = false
        holdTimer.stop()
        closeDelay.restart()
    }
    Timer { id: holdTimer; interval: 5000; onTriggered: root.hide() }
    Timer { id: closeDelay; interval: 400; onTriggered: { root.active = false; root.notif = null } }

    // Click: same semantics as the Super+i picker's openItem — retain
    // messages as history, fire the default action, focus the window.
    function activate() {
        const n = notif
        const isMsg = Notifications.isMessageAppName(nApp)
        if (n) {
            if (isMsg) {
                Notifications.retain(n.id, nApp, nSummary, nWindowId)
                Notifications.markSeenById(n.id)
            }
            const acts = n.actions || []
            for (let i = 0; i < acts.length; i++)
                if (acts[i].identifier === "default") { acts[i].invoke(); break }
            if (!isMsg) Notifications.clearOne(n)
        }
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/niri/scripts/notification-dispatch",
            "--past", nApp, nSummary, nWindowId,
        ])
        hide()
    }

    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        // Tucked fully above the window top when closed — it slides out
        // from under the notch's bottom edge.
        y: root.open ? -Theme.notchRadius : -(height + 4)
        height: 52
        width: root.open ? Math.min(content.implicitWidth + 32, 560) : 140
        radius: height / 2
        topLeftRadius: root.open ? 12 : height / 2
        topRightRadius: root.open ? 12 : height / 2
        color: Theme.notch
        border.color: Theme.hairline
        border.width: 1
        opacity: root.open ? 1 : 0
        clip: true

        Behavior on y {
            NumberAnimation {
                duration: 380
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.34, 1.4, 0.64, 1.0, 1.0, 1.0]
            }
        }
        Behavior on width {
            NumberAnimation {
                duration: 380
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.34, 1.4, 0.64, 1.0, 1.0, 1.0]
            }
        }
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Row {
            id: content
            anchors.verticalCenter: parent.verticalCenter
            // Keep content visually centered under the notch even as width animates.
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 10
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Item {
                width: 30; height: 30
                anchors.verticalCenter: parent.verticalCenter
                ClippingRectangle {
                    anchors.fill: parent
                    radius: 15
                    color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
                    Image {
                        id: avatar
                        anchors.fill: parent
                        source: root.nImage
                        visible: status === Image.Ready
                        sourceSize.width: 60; sourceSize.height: 60
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: avatar.status !== Image.Ready
                        text: root.nSummary.length ? root.nSummary[0].toUpperCase() : "•"
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        font.weight: 700
                        renderType: Text.NativeRendering
                    }
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Text {
                    text: root.nSummary
                    color: Theme.fg
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, 420)
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: 600
                    renderType: Text.NativeRendering
                }
                Text {
                    visible: text.length > 0
                    text: root.nBody
                    color: Theme.fg_muted
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, 420)
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    renderType: Text.NativeRendering
                }
            }

            Rectangle {
                visible: root.extraCount > 0
                anchors.verticalCenter: parent.verticalCenter
                width: extraText.implicitWidth + 12
                height: extraText.implicitHeight + 6
                radius: height / 2
                color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10)
                Text {
                    id: extraText
                    anchors.centerIn: parent
                    text: "+" + root.extraCount
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.weight: 700
                    renderType: Text.NativeRendering
                }
            }
        }

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.activate() }
    }
}
