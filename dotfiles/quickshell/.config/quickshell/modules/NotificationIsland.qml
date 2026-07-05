import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "."

// Dynamic-island notification capsule — the sole presentation surface.
// Springs down out of the bar's centered notch when a notification
// arrives (Notifications.present), holds a few seconds, springs back.
// Click = the same activation the Super+i picker does (open channel /
// focus window). Owns the ephemeral lifecycle: non-tray notifications
// (screenshots, notify-send) are dismissed once their showing ends.
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

    // Overlaps the bar region (Overlay layer renders above it) so the
    // capsule can cover the notch's bottom border where it attaches and
    // read as one continuous shape growing out of the notch.
    anchors.top: true
    margins.top: 0
    implicitWidth: 600
    implicitHeight: Theme.barHeight + 130
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
    property int nId: 0
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
        if (notif && nId !== (n.id || 0)) endShowing()
        notif = n
        nId = n.id || 0
        nApp = n.appName || ""
        nSummary = n.summary || ""
        nBody = (n.body || "").replace(/<[^>]+>/g, "").replace(/\n/g, "  ")
        const img = n.image || ""
        nImage = img ? (img.startsWith("/") ? "file://" + img : img) : ""
        nWindowId = (n.hints && n.hints["niri-window"] !== undefined)
            ? String(n.hints["niri-window"]) : ""
        extraCount = wasOpen ? extraCount + 1 : 0
        Notifications.setToastVisible(nId, true)
        closeDelay.stop()
        active = true
        open = true
        holdTimer.restart()
    }

    // A notification's showing is over (replaced or capsule closed): stop
    // reporting it on-screen, and drop non-tray ones — they have no home in
    // the Super+i center, and with no toast lifecycle nothing else dismisses
    // them. Looked up by id: the object may already be gone.
    function endShowing() {
        Notifications.setToastVisible(nId, false)
        if (Notifications.trayApps.indexOf(nApp.toLowerCase()) === -1) {
            const n = Notifications._findById(nId)
            if (n) n.dismiss()
        }
    }

    function hide() {
        open = false
        holdTimer.stop()
        closeDelay.restart()
    }
    Timer { id: holdTimer; interval: 5000; onTriggered: root.hide() }
    Timer {
        id: closeDelay
        interval: 400
        onTriggered: {
            root.endShowing()
            root.active = false
            root.notif = null
        }
    }

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

    // Same two-rectangle construction as the bar's notch (outer =
    // hairline, inner = fill inset 1px on left/right/bottom, flush top)
    // so the joint is invisible: the capsule's top overlaps the notch's
    // bottom border and shares its exact colors.
    // 4 logical px so the capsule's top edge lands on an integer physical
    // pixel at 1.75 scale — a fractional edge leaves an antialiased row
    // that lets the notch border bleed through.
    readonly property int seamOverlap: 4
    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.barHeight - root.seamOverlap
        height: root.open ? 52 + root.seamOverlap : 0
        width: root.open ? Math.min(content.implicitWidth + 32, 560) : 48
        topLeftRadius: 0
        topRightRadius: 0
        bottomLeftRadius: Math.min(height / 2, Theme.notchRadius + 6)
        bottomRightRadius: Math.min(height / 2, Theme.notchRadius + 6)
        // Root is fill-colored so the part tucked inside the notch is
        // invisible against it; the hairline outline is an overlay that
        // starts at the bar's bottom edge.
        color: Theme.notch
        clip: true

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: root.seamOverlap
            color: Theme.hairline
            topLeftRadius: 0
            topRightRadius: 0
            bottomLeftRadius: capsule.bottomLeftRadius
            bottomRightRadius: capsule.bottomRightRadius
            clip: true

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 1
                anchors.rightMargin: 1
                anchors.bottomMargin: 1
                // Rounded rects antialias every edge; a flush top edge
                // leaves a partial-alpha row that tints the seam. Overshoot
                // the top so the parent's clip cuts it with a hard edge.
                anchors.topMargin: -2
                color: Theme.notch
                topLeftRadius: 0
                topRightRadius: 0
                bottomLeftRadius: Math.max(0, capsule.bottomLeftRadius - 1)
                bottomRightRadius: Math.max(0, capsule.bottomRightRadius - 1)
            }
        }

        Behavior on height {
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

        Row {
            id: content
            // Center within the visible (below-bar) portion of the capsule.
            y: root.seamOverlap + (parent.height - root.seamOverlap - height) / 2
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
