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
    subtitleField: "kind"

    items: buildItems(Notifications.tracked, Notifications.seenGen)

    onEnter: item => {
        if (!item || item.divider) return
        NotificationJumpPickerState.open = false
        const n = item.notif
        // Fire the live default action first (slk opens the channel/thread) —
        // it must run before any dismiss, which tears the action down. Works
        // for "earlier" too: they're still live.
        if (n && n.actions) {
            const acts = n.actions
            for (let i = 0; i < acts.length; i++) {
                if (acts[i].identifier === "default") { acts[i].invoke(); break }
            }
        }
        // Acting on a Claude prompt clears it; Slack/Discord messages stay as
        // history (just marked read).
        if (n) {
            if (Notifications.isMessageApp(n)) Notifications.markSeen(n)
            else Notifications.clearOne(n)
        }
        // Focus the window/app.
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/niri/scripts/notification-dispatch",
            "--past", item.app, item.summary, String(item.windowId || "")
        ])
    }

    function mkItem(n) {
        const wid = (n.hints && n.hints["niri-window"] !== undefined) ? n.hints["niri-window"] : ""
        return {
            notif: n,
            app: n.appName || "",
            summary: n.summary || "",
            windowId: wid,
            label: n.summary || n.appName || "notification",
            kind: n.appName || "",
        }
    }

    function buildItems(tracked, gen) {
        const all = (tracked && tracked.values) ? tracked.values.slice() : []
        // Only tray apps ever show here — a non-tray notif briefly tracked
        // during its toast window must not leak into the center.
        const vals = all.filter(n => Notifications.isTrayApp(n))
        vals.sort((a, b) => (b.id || 0) - (a.id || 0))   // newest first
        const unseen = vals.filter(n => !Notifications.isSeen(n))
        const seen = vals.filter(n => Notifications.isSeen(n))
        const out = []
        if (unseen.length) {
            out.push({ divider: true, label: "current" })
            for (let i = 0; i < unseen.length; i++) out.push(mkItem(unseen[i]))
        }
        if (seen.length) {
            out.push({ divider: true, label: "earlier" })
            for (let i = 0; i < seen.length; i++) out.push(mkItem(seen[i]))
        }
        return out
    }
}
