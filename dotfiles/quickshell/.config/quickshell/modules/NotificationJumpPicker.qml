import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Super+i notification center. Every entry is a LIVE notification (we never
// auto-dismiss them), split by recency: the newest few under "current", older
// ones under "earlier". Selecting any of them fires its live default action
// (e.g. slk opens the channel/thread) and focuses the window — so even
// "earlier" entries open their channel, because they're still live. Toasts
// fade on their own (NotificationOverlay) and the live list is bounded by
// Notifications.liveMax, so this doesn't pile up.
Picker {
    id: root

    open: NotificationJumpPickerState.open
    onCloseRequested: NotificationJumpPickerState.open = false

    placeholder: "notification"
    subtitleField: "kind"

    readonly property int recentCount: 4

    items: buildItems(Notifications.tracked)

    onEnter: item => {
        if (!item || item.divider) return
        NotificationJumpPickerState.open = false
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

    function buildItems(tracked) {
        const vals = (tracked && tracked.values) ? tracked.values.slice() : []
        vals.sort((a, b) => (b.id || 0) - (a.id || 0))   // newest first
        const out = []
        for (let i = 0; i < vals.length; i++) {
            if (i === 0) out.push({ divider: true, label: "current" })
            else if (i === root.recentCount) out.push({ divider: true, label: "earlier" })
            const n = vals[i]
            const wid = (n.hints && n.hints["niri-window"] !== undefined) ? n.hints["niri-window"] : ""
            out.push({
                notif: n,
                app: n.appName || "",
                summary: n.summary || "",
                windowId: wid,
                label: n.summary || n.appName || "notification",
                kind: n.appName || "",
            })
        }
        return out
    }
}
