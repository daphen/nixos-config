import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Super+i notification center. Shows only the apps worth keeping — Slack,
// Discord, Claude (Notifications.trayApps); screenshots and other system
// notifs toast once and never land here. Entries split by whether you've
// looked at the source: unseen under "current", seen under "earlier".
// Selecting one fires its live default action (e.g. slqs opens the
// channel/thread) and focuses the window. Slack/Discord messages stay as
// history; Claude prompts clear when you act on them.
Picker {
    emptyText: "no notifications"
    id: root

    open: NotificationJumpPickerState.open
    onCloseRequested: NotificationJumpPickerState.open = false

    placeholder: "notification"
    iconField: "icon"
    // right-slot hints; drop the redundant j/k "move" on the left
    navHint: false
    altLabel: "ctrl+r: mark read · ctrl+o: expand"
    // Ctrl+O unfolds the notification body (clipboard-picker convention)
    previewTextField: "body"
    // Ctrl+R marks read in place: mail invokes the daemon's "read" action
    // (server-side mark-read); everything else just clears from the center
    onCtrlR: item => {
        const n = item.notif
        let fired = false
        if (n && n.actions) {
            for (let i = 0; i < n.actions.length; i++)
                if (n.actions[i].identifier === "read") { n.actions[i].invoke(); fired = true; break }
        }
        if (!fired) root.mailFallback(item, "read")
        Notifications.markSeenById(item.id)
        if (n) Notifications.clearOne(n)
    }

    // Mail history entries outlive their live Notification — the mlqs daemon
    // keeps each id's deep-link, so re-dispatch over its socket instead.
    function mailFallback(item, action) {
        if ((item.app || "").toLowerCase() !== "mlqs" || item.id === undefined) return
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/niri/scripts/mlqs-notifact",
            String(item.id), action
        ])
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
        // Fire the live default action (slqs/dsqrd opens the channel/thread).
        // Only present while the notification is still live.
        let fired = false
        if (n && n.actions) {
            const acts = n.actions
            for (let i = 0; i < acts.length; i++) {
                if (acts[i].identifier === "default") { acts[i].invoke(); fired = true; break }
            }
        }
        if (!fired) root.mailFallback(item, "default")
        // Claude prompts clear on interact (no live action; just remove).
        if (!isMsg && n) Notifications.clearOne(n)
        // Focus the window/app.
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/niri/scripts/notification-dispatch",
            "--past", item.app, item.summary, String(item.windowId || "")
        ])
    }

    function _icon(appName, appIcon) { return Notifications.appIconFor(appName, appIcon) }

    function mkItemLive(n) {
        const wid = (n.hints && n.hints["niri-window"] !== undefined) ? String(n.hints["niri-window"]) : ""
        return {
            id: n.id, notif: n, app: n.appName || "", summary: n.summary || "", windowId: wid,
            body: n.body || "", label: n.summary || n.appName || "notification", icon: _icon(n.appName, n.appIcon),
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
