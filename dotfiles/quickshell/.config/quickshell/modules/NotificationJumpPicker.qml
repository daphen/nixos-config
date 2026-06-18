import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Super+i notification center. Every entry is a LIVE notification (we never
// auto-dismiss them), split by whether you've looked at its source: unseen
// ones under "current", seen ones under "earlier". Selecting any of them fires
// its live default action (e.g. slk opens the channel/thread) and focuses the
// window — so even "earlier" entries open their channel, because they're still
// live. The list is bounded by Notifications.liveMax, so it doesn't pile up.
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
        if (item.notif) Notifications.markSeen(item.notif)
        // Fire the live default action synchronously (slk opens the
        // channel/thread). Works for "earlier" too — they're still live.
        if (item.notif && item.notif.actions) {
            const acts = item.notif.actions
            for (let i = 0; i < acts.length; i++) {
                if (acts[i].identifier === "default") { acts[i].invoke(); break }
            }
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
        const vals = (tracked && tracked.values) ? tracked.values.slice() : []
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
