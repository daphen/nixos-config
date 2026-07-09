import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Super+i notification center. Shows only the apps worth keeping — Slack,
// Discord, Claude (Notifications.trayApps); screenshots and other system
// notifs toast once and never land here. Entries split by whether you've
// looked at the source: unseen under "current", seen under "earlier".
// Selecting one fires its live default action (e.g. slk opens the
// channel/thread) and focuses the window. Slack/Discord messages stay as
// history; Claude prompts clear when you act on them.
Picker {
    id: root

    open: NotificationJumpPickerState.open
    onCloseRequested: NotificationJumpPickerState.open = false

    placeholder: "notification"
    iconField: "icon"
    // Ctrl+O unfolds the notification body (clipboard-picker convention)
    previewTextField: "body"
    // Ctrl+R marks read in place: mail invokes the daemon's "read" action
    // (server-side mark-read); everything else just clears from the center
    onCtrlR: item => {
        const n = item.notif
        if (n && n.actions) {
            for (let i = 0; i < n.actions.length; i++)
                if (n.actions[i].identifier === "read") { n.actions[i].invoke(); break }
        }
        Notifications.markSeenById(item.id)
        if (n) Notifications.clearOne(n)
    }

    items: buildItems(Notifications.tracked, Notifications.seenGen,
                      Notifications.retained, Notifications.retainedGen)

    // NOTE: named openItem, NOT activate — Picker has its own activate() that
    // its Enter handling calls; shadowing it breaks Enter inside the picker.
    onEnter: item => root.openItem(item)

    // Super+i (showOrJump): exactly one toast on screen → act on it directly,
    // no picker round-trip; zero or several → the picker as usual.
    Connections {
        target: NotificationJumpPickerState
        function onJumpRequested() {
            const vis = Notifications.visibleTrayToasts()
            if (vis.length === 1) root.openItem(root.mkItemLive(vis[0]))
            else NotificationJumpPickerState.open = true
        }
    }

    function openItem(item) {
        if (!item || item.divider) return
        NotificationJumpPickerState.open = false
        const n = item.notif   // live Notification, or null for a retained entry
        const isMsg = Notifications.isMessageAppName(item.app)
        // A message's open-channel action deletes the live notification, so
        // retain its data first (and mark it read) — it stays in the center.
        if (isMsg) {
            Notifications.retain(item.id, item.app, item.summary, item.windowId)
            Notifications.markSeenById(item.id)
        }
        // Fire the live default action (slk/dsqrd opens the channel/thread).
        // Only present while the notification is still live.
        if (n && n.actions) {
            const acts = n.actions
            for (let i = 0; i < acts.length; i++) {
                if (acts[i].identifier === "default") { acts[i].invoke(); break }
            }
        }
        // Claude prompts clear on interact (no live action; just remove).
        if (!isMsg && n) Notifications.clearOne(n)
        // Focus the window/app.
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/niri/scripts/notification-dispatch",
            "--past", item.app, item.summary, String(item.windowId || "")
        ])
    }

    // Monochrome brand icon for the row, tinted to the theme via MultiEffect.
    // slqs deliberately tags its notifications AppName "slk" (the old TUI's
    // name, kept for downstream consumers) and dsqrd uses "Discord"; map the
    // raw ids to a bundled white-fill SVG under assets/.
    function _icon(appName) {
        const a = (appName || "").toLowerCase()
        if (a === "slack" || a === "slk" || a === "slqs") return Qt.resolvedUrl("../assets/slack.svg")
        if (a === "discord" || a === "endcord" || a === "dsqrd") return Qt.resolvedUrl("../assets/discord.svg")
        if (a === "mlqs") return Qt.resolvedUrl("../assets/mail.svg")
        if (a === "kitty") return Qt.resolvedUrl("../assets/claude.svg")
        return ""
    }

    function mkItemLive(n) {
        const wid = (n.hints && n.hints["niri-window"] !== undefined) ? String(n.hints["niri-window"]) : ""
        return {
            id: n.id, notif: n, app: n.appName || "", summary: n.summary || "", windowId: wid,
            body: n.body || "", label: n.summary || n.appName || "notification", icon: _icon(n.appName),
        }
    }

    function mkItemRetained(e) {
        return {
            id: e.id, notif: null, app: e.app, summary: e.summary, windowId: e.windowId,
            body: e.summary || "", label: e.summary || e.app || "notification", icon: _icon(e.app),
        }
    }

    function buildItems(tracked, sgen, retained, rgen) {
        // Center contents = live tracked tray notifications ∪ retained (messages
        // whose live notification was deleted when its channel was opened).
        const live = (tracked && tracked.values) ? tracked.values.slice() : []
        const liveTray = live.filter(n => Notifications.isTrayApp(n))
        const liveIds = {}
        const items = []
        for (let i = 0; i < liveTray.length; i++) { liveIds[liveTray[i].id] = true; items.push(mkItemLive(liveTray[i])) }
        const ret = retained || []
        for (let i = 0; i < ret.length; i++) if (!liveIds[ret[i].id]) items.push(mkItemRetained(ret[i]))
        items.sort((a, b) => (b.id || 0) - (a.id || 0))   // newest first
        const unseen = items.filter(it => !Notifications.isSeenId(it.id))
        const seen = items.filter(it => Notifications.isSeenId(it.id))
        const out = []
        if (unseen.length) {
            out.push({ divider: true, label: "current" })
            for (let i = 0; i < unseen.length; i++) out.push(unseen[i])
        }
        if (seen.length) {
            out.push({ divider: true, label: "earlier" })
            for (let i = 0; i < seen.length; i++) out.push(seen[i])
        }
        return out
    }
}
