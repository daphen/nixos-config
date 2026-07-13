import QtQuick
import QtQuick.Effects
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
    property string nAppIcon: ""
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
        nAppIcon = Notifications.appIconFor(n.appName)
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
    // Wordy messages (3+ wrapped lines) get 2s more reading time.
    Timer { id: holdTimer; interval: bodyText.lineCount >= 3 ? 7000 : 5000; onTriggered: root.hide() }
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
    // Fullscreen content covers the bar (top layer), so there is no notch
    // to grow out of — detach: sit flush near the top edge as a free
    // capsule, fully rounded, with its own top border. Fullscreen is
    // inferred from the focused window filling the screen height (nothing
    // else reaches past the bar's exclusive zone).
    readonly property bool detached: {
        const _ = NiriState.version
        const w = NiriState.windows[NiriState.focusedWindowId()]
        if (!w || !w.layout || !w.layout.window_size || w.is_floating) return false
        return root.screen && w.layout.window_size[1] >= root.screen.height
    }

    // pixel at 1.75 scale — a fractional edge leaves an antialiased row
    // that lets the notch border bleed through.
    readonly property int seamOverlap: detached ? 0 : 4
    Rectangle {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.detached ? 8 : Theme.barHeight - root.seamOverlap
        height: root.open ? Math.max(52, content.implicitHeight + 22) + root.seamOverlap : 0
        // floor keeps one-word notifications from rendering as stubby pills
        width: root.open ? Math.min(Math.max(content.implicitWidth + 32, 300), 560) : 48
        topLeftRadius: root.detached ? bottomLeftRadius : 0
        topRightRadius: root.detached ? bottomRightRadius : 0
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
            topLeftRadius: capsule.topLeftRadius
            topRightRadius: capsule.topRightRadius
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
                // the top so the parent's clip cuts it with a hard edge —
                // except detached, where the top border is real.
                anchors.topMargin: root.detached ? 1 : -2
                color: Theme.notch
                topLeftRadius: root.detached ? Math.max(0, capsule.topLeftRadius - 1) : 0
                topRightRadius: root.detached ? Math.max(0, capsule.topRightRadius - 1) : 0
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
                    // no avatar → the app's brand glyph; unknown app → monogram
                    Image {
                        id: appGlyph
                        anchors.centerIn: parent
                        width: 15; height: 15
                        visible: false
                        source: root.nAppIcon
                        sourceSize.width: 30; sourceSize.height: 30
                        asynchronous: true
                    }
                    MultiEffect {
                        anchors.fill: appGlyph
                        source: appGlyph
                        visible: avatar.status !== Image.Ready && appGlyph.status === Image.Ready
                        colorization: 1
                        colorizationColor: Theme.fg_secondary
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: avatar.status !== Image.Ready
                                 && (root.nAppIcon === "" || appGlyph.status !== Image.Ready)
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
                // implicitWidth is the unwrapped ideal, so short messages
                // keep the capsule compact and long ones cap at 420 and wrap.
                width: Math.min(Math.max(summaryText.implicitWidth, bodyText.implicitWidth), 420)
                Text {
                    id: summaryText
                    text: root.nSummary
                    color: Theme.fg
                    elide: Text.ElideRight
                    width: parent.width
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: 600
                    renderType: Text.NativeRendering
                }
                Text {
                    id: bodyText
                    visible: text.length > 0
                    text: root.nBody
                    color: Theme.fg
                    elide: Text.ElideRight
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    width: parent.width
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
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
