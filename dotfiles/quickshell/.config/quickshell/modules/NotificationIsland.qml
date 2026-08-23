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
    // Track the capsule: the fixed 130 clipped tall ask capsules (button row +
    // multi-line body) at the window edge, eating the bottom border.
    implicitHeight: Theme.barHeight + Math.max(130, capsule.height + 24)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-island"
    WlrLayershell.keyboardFocus: answerMode ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    // Input only over the capsule — the rest of the surface passes clicks
    // through to whatever is beneath.
    mask: Region { item: capsule }
    visible: active

    property bool active: false
    property bool open: false
    property bool answerMode: false
    // Per-scope, theme-aware avatar for agent questions: the personal cockpit's
    // note-logo (ink follows the theme) vs the Lovable heart for work scopes.
    readonly property string askAvatar: {
        if (!showingAsk || !ask) return ""
        const sc = ask.scope || "personal"
        if (sc === "lovable" || sc === "work") return Qt.resolvedUrl("../assets/lovable-heart.svg")
        return Qt.resolvedUrl(Theme.mode === "light" ? "../assets/icon-light.svg" : "../assets/icon-dark.svg")
    }
    property int answerCur: 0   // which option the keyboard cursor sits on
    property var ask: null
    readonly property bool showingAsk: !!ask && nApp === "Agent" && notif === null
    readonly property bool heidrFocused: {
        const _ = NiriState.version
        const t = NiriState.focusedTitle()
        return t.startsWith("cockpit-qs") || t.startsWith("heidr")
    }
    readonly property var askOptions: ask && ask.method === "confirm" ? ["Yes", "No"] : []

    // Current presentation.
    property var notif: null           // live Notification (may die under us)
    property int nId: 0
    property string nApp: ""
    property string nSummary: ""
    property string nBody: ""
    property string nImage: ""
    property string nAppIcon: ""
    property bool nIsCalendar: false   // mlqs meeting reminder → accent glyph, not grey
    // Phone-origin: marked on the RIGHT, so the left badge stays free for the
    // caller's picture rather than being spent on a provenance glyph.
    property bool nIsPhone: false
    property string nWindowId: ""
    property int extraCount: 0         // arrivals that replaced content this show

    Connections {
        target: Notifications
        function onPresent(n) { root.show(n) }
    }
    Connections {
        target: AgentAskState
        function onGenChanged() { root.refreshAsk() }
        function onFocusConfirmRequested(item) {
            root.ask = item
            root.showAsk(item)
            root.answerMode = true
            root.answerCur = 0
            answerKeys.forceActiveFocus()
        }
    }
    onHeidrFocusedChanged: refreshAsk()

    function refreshAsk() {
        if (heidrFocused) {
            if (showingAsk && open) hide()
            return
        }
        const available = AgentAskState.asks
        if (ask && available.some(item => item.key === ask.key)) {
            if (!showingAsk) showAsk(ask)
            return
        }
        ask = available.length ? available[0] : null
        if (ask) showAsk(ask)
        else {
            answerMode = false
            if (open && nApp === "Agent") hide()
        }
    }

    function showAsk(item) {
        if (notif) endShowing()
        notif = null
        ask = item
        nId = 0
        nApp = "Agent"
        nSummary = item.title || "Agent needs input"
        nBody = item.message || ""
        nImage = ""
        nAppIcon = ""
        nIsCalendar = false
        nIsPhone = false
        nWindowId = ""
        extraCount = Math.max(0, AgentAskState.asks.length - 1)
        closeDelay.stop()
        holdTimer.stop()
        active = true
        open = true
    }

    function answerAskOption(index, value) {
        if (!ask) return
        answerMode = false
        const payload = ask.method === "confirm" ? { confirmed: index === 0 } : { value: value }
        const current = ask
        ask = null
        AgentAskState.answer(current, payload)
        refreshAsk()
    }

    function show(n) {
        // An ask that is SUPPRESSED (cockpit focused shows it in the rail
        // instead) must not also swallow ordinary notifications — that muted
        // Slack/calendar entirely whenever any agent held a question.
        if (showingAsk && !heidrFocused) return
        const wasOpen = open
        if (notif && nId !== (n.id || 0)) endShowing()
        notif = n
        nId = n.id || 0
        nApp = n.appName || ""
        nIsPhone = Notifications.isPhoneNotif(nApp)
        nSummary = n.summary || ""
        nBody = (n.body || "").replace(/<[^>]+>/g, "").replace(/\n/g, "  ")
        // Only a real avatar path/URL is an avatar. A bare freedesktop icon
        // NAME (mlqs sends mail-unread / x-office-calendar) can't be loaded and
        // would just fail-blank the same way for every mlqs notif — drop it so
        // the mapped brand/calendar glyph (appIconFor) always shows instead.
        // The avatar (slqs/dsqrd image-path hint) arrives as an
        // image://icon/<abs-path> quickshell provider URL — use it as-is (a
        // file:// of the same path doesn't render here). Only a wrapped ABSOLUTE
        // path is a real avatar; a bare freedesktop icon name (mlqs mail-unread)
        // is dropped so the mapped brand/calendar glyph shows instead.
        const raw = n.image || ""
        let src = ""
        if (raw.startsWith("image://icon/")) src = raw.slice(13).startsWith("/") ? raw : ""
        else if (raw.startsWith("image://") || raw.startsWith("file://") || raw.startsWith("http")) src = raw
        else if (raw.startsWith("/")) src = "file://" + raw
        nImage = src
        nIsCalendar = Notifications.isCalNotif(n)
        nAppIcon = nIsCalendar ? Notifications.calendarIcon : Notifications.appIconFor(n.appName, n.appIcon)
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

    Connections {
        target: Notifications
        function onToastHandled(id) { if (root.open && root.nId === id) root.hide() }
    }
    // Wordy messages (3+ wrapped lines) get 2s more reading time.
    Timer { id: holdTimer; interval: bodyText.lineCount >= 3 ? 7000 : 5000; onTriggered: if (!root.showingAsk) root.hide() }
    Timer {
        id: closeDelay
        interval: 400
        onTriggered: {
            if (!root.showingAsk) root.endShowing()
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
        const g = NiriState.focusedWindowGeom()
        if (!g || g.floating || !root.screen) return false
        return NiriState.focusedIsFullscreen(root.screen.height)
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

        Column {
            id: content
            // Center within the visible (below-bar) portion of the capsule.
            y: root.seamOverlap + (parent.height - root.seamOverlap - height) / 2
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Row {
            id: contentTop
            spacing: 10

            Item {
                width: 30; height: 30
                anchors.verticalCenter: parent.verticalCenter
                ClippingRectangle {
                    anchors.fill: parent
                    radius: 15
                    // Ask avatars are bare glyphs — no ground behind the logo.
                    color: root.showingAsk ? "transparent" : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
                    Image {
                        id: avatar
                        anchors.fill: parent
                        anchors.margins: root.showingAsk ? 2 : 0
                        source: root.showingAsk ? root.askAvatar : root.nImage
                        visible: status === Image.Ready
                        // SVGs rasterize AT sourceSize — forcing a square there squishes
                        // before the fit can help. Ask glyphs rasterize at true aspect.
                        sourceSize.width: root.showingAsk ? 48 : 60
                        sourceSize.height: 60
                        // Fit, not crop: the scope glyphs aren't square (122:152).
                        fillMode: root.showingAsk ? Image.PreserveAspectFit : Image.PreserveAspectCrop
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
                        colorizationColor: root.nIsCalendar ? Theme.sky : Theme.fg_secondary
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
                }
            }

            // Provenance marker: this arrived from the phone. Sits opposite the
            // avatar so the left badge can carry the caller's picture.
            Item {
                visible: root.nIsPhone
                anchors.verticalCenter: parent.verticalCenter
                width: 14; height: 14
                Image {
                    id: phoneGlyph
                    anchors.fill: parent
                    source: Qt.resolvedUrl("../assets/phone.svg")
                    sourceSize.width: 28; sourceSize.height: 28
                    visible: false
                    asynchronous: true
                }
                MultiEffect {
                    anchors.fill: phoneGlyph
                    source: phoneGlyph
                    visible: phoneGlyph.status === Image.Ready
                    colorization: 1
                    colorizationColor: Theme.fg_muted
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
                }
            }
            }

            // Answer buttons: their own bottom row, centered in the capsule.
            Row {
                visible: root.showingAsk && root.askOptions.length > 0
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Repeater {
                    model: root.askOptions
                    Rectangle {
                        required property string modelData
                        required property int index
                        width: Math.max(optionText.implicitWidth + 26, 64)
                        height: 28
                        radius: height / 2
                        readonly property bool cursorOn: root.answerMode && root.answerCur === index
                        color: (optionTap.hovered || cursorOn) ? Theme.fg : Theme.surface2
                        border.width: 1
                        border.color: Theme.hairline
                        Text {
                            id: optionText
                            anchors.centerIn: parent
                            text: modelData
                            color: (optionTap.hovered || parent.cursorOn) ? Theme.bg : Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            font.weight: 600
                        }
                        HoverHandler { id: optionTap; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.answerAskOption(index, modelData) }
                    }
                }
            }
        }

        Item {
            id: answerKeys
            anchors.fill: parent
            focus: root.answerMode
            Keys.onPressed: event => {
                if (!root.answerMode) return
                const n = root.askOptions.length
                if (event.key === Qt.Key_H || event.key === Qt.Key_Left)
                    root.answerCur = Math.max(0, root.answerCur - 1)
                else if (event.key === Qt.Key_L || event.key === Qt.Key_Right)
                    root.answerCur = Math.min(Math.max(0, n - 1), root.answerCur + 1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    root.answerAskOption(root.answerCur, root.askOptions[root.answerCur] || "")
                else if (event.key === Qt.Key_Y) root.answerAskOption(0, "Yes")
                else if (event.key === Qt.Key_N) root.answerAskOption(1, "No")
                else if (event.key === Qt.Key_Escape) root.answerMode = false
                else return
                event.accepted = true
            }
        }

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler {
            enabled: !root.showingAsk || root.askOptions.length === 0
            onTapped: {
                if (!root.showingAsk) root.activate()
                else if (root.ask.method === "select") NotificationJumpPickerState.open = true
                else AgentAskState.openInput(root.ask)
            }
        }
    }
}
