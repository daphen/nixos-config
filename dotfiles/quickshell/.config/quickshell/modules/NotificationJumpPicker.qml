import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Super+i shows unseen, actionable notifications. AI prompts use the cockpit
// activity surfaces instead, and seen entries do not remain as history here.
Picker {
    emptyText: "no notifications"
    id: root

    property bool handlesJump: true

    open: NotificationJumpPickerState.open
    onCloseRequested: NotificationJumpPickerState.open = false

    placeholder: "notification"
    iconField: "icon"
    trailingField: "inbox"
    // right-slot hints; drop the redundant j/k "move" on the left
    navHint: false
    altLabel: "ctrl+y/n: respond · ctrl+r: read · ctrl+shift+r: read all · ctrl+o: expand"
    // Ctrl+O unfolds the notification body (clipboard-picker convention)
    previewTextField: "body"
    // Ctrl+R marks read in place: mail invokes the daemon's "read" action
    // (server-side mark-read); everything else just clears from the center
    // Ctrl+Y / Ctrl+N answer calendar invitations when actions are available.
    function _invokeMatching(item, rx) {
        const n = item.notif
        if (!n || !n.actions) return false
        for (let i = 0; i < n.actions.length; i++)
            if (rx.test(n.actions[i].text || "") || rx.test(n.actions[i].identifier || "")) {
                n.actions[i].invoke(); return true
            }
        return false
    }
    onCtrlY: item => {
        if (item.cal && _invokeMatching(item, /accept|yes|going/i)) { Notifications.markSeenById(item.id); return }
    }
    onCtrlN: item => {
        if (item.cal && _invokeMatching(item, /decline|no(?!t)/i)) { Notifications.markSeenById(item.id); return }
    }
    function markRead(item) {
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
    onCtrlR: item => root.markRead(item)
    onCtrlShiftR: () => {
        const pending = root.items.slice()
        for (let i = 0; i < pending.length; i++)
            if (!pending[i].divider) root.markRead(pending[i])
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

    items: buildItems(Notifications.tracked, Notifications.seenGen)

    // NOTE: named openItem, NOT activate — Picker has its own activate() that
    // its Enter handling calls; shadowing it breaks Enter inside the picker.
    onEnter: item => root.openItem(item)

    // Super+i (showOrJump): exactly one toast on screen → act on it directly,
    // no picker round-trip; zero or several → the picker as usual.
    Connections {
        target: NotificationJumpPickerState
        function onJumpRequested() {
            if (!root.handlesJump) return
            const vis = Notifications.visibleToasts()
                .filter(n => !Notifications.isAiNotification(n))
            if (vis.length === 1) root.openItem(root.mkItemLive(vis[0]))
            else NotificationJumpPickerState.open = true
        }
    }

    function openItem(item) {
        if (!item || item.divider) return
        NotificationJumpPickerState.open = false
        // Close the capsule up front: acting on it is the answer to it, and for
        // message apps nothing below dismisses the live notification.
        Notifications.toastHandled(item.id)
        const n = item.notif   // live Notification, or null for a retained entry
        const isMsg = Notifications.isMessageAppName(item.app)
        if (isMsg) Notifications.markSeenById(item.id)
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
        const cal = Notifications.isCalNotif(n)
        const summary = n.summary || ""
        const parts = (n.appName || "").toLowerCase() === "mlqs" ? summary.split(/\s+·\s+/) : [summary]
        const inbox = parts.length > 1 ? parts.pop() : ""
        // Invitations use the same card grammar as agent questions: chips name
        // the actions, ctrl+y/n answer.
        let chips
        if (cal && n.actions && n.actions.length)
            chips = n.actions.filter(a => (a.identifier || "") !== "default").map(a => a.text || a.identifier).slice(0, 3)
        return {
            id: n.id, notif: n, app: n.appName || "", summary: summary, windowId: wid, cal: cal,
            body: n.body || "", label: parts.join(" · ") || n.appName || "notification", inbox: inbox,
            icon: cal ? Notifications.calendarIcon : _icon(n.appName, n.appIcon),
            chips: chips && chips.length ? chips : undefined,
        }
    }

    function buildItems(tracked, sgen) {
        const live = (tracked && tracked.values) ? tracked.values.slice() : []
        const missed = live
            .filter(n => Notifications.isTrayApp(n)
                && !Notifications.isAiNotification(n)
                && !Notifications.isSeen(n))
            .map(n => mkItemLive(n))
            .sort((a, b) => (b.id || 0) - (a.id || 0))
        if (!missed.length) return []
        return [{ divider: true, label: "missed" }].concat(missed)
    }
}
