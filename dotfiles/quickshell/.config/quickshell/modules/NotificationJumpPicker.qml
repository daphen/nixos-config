import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Super+i notification center: active notifications under "current",
// recently-dismissed under "earlier". Selecting jumps to the window/app;
// closing the picker (select or escape) clears the active ones — they stay
// in history. Every entry dispatches via stored info (window id for kitty,
// app+summary otherwise), so clearing on close can't race the jump.
Picker {
    id: root

    open: NotificationJumpPickerState.open
    onCloseRequested: NotificationJumpPickerState.open = false

    // Opening the picker acknowledges the current notifications: clear them
    // once it has fully closed by any means (select, escape, IPC hide) — they
    // remain in history. `active` flips false ~300ms after close.
    onActiveChanged: if (!active) Notifications.dismissAllActive()

    placeholder: "notification"
    subtitleField: "kind"

    items: buildItems(Notifications.tracked, Notifications.history)

    onEnter: item => {
        if (!item || item.divider) return
        NotificationJumpPickerState.open = false
        // Fire the live notification's default action SYNCHRONOUSLY here (e.g.
        // slk opens the channel/thread) — before the picker closes and
        // clear-on-close dismisses it. Doing this via the dispatch script
        // raced the dismiss and lost.
        if (item.notif && item.notif.actions) {
            const acts = item.notif.actions
            for (let i = 0; i < acts.length; i++) {
                if (acts[i].identifier === "default") { acts[i].invoke(); break }
            }
        }
        // Focus the window/app via stored info — race-free with the dismiss.
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/niri/scripts/notification-dispatch",
            "--past", item.app, item.summary, String(item.windowId || "")
        ])
    }

    function entry(appName, summary, windowId) {
        return {
            app: appName || "",
            summary: summary || "",
            windowId: (windowId !== undefined && windowId !== null) ? windowId : "",
            label: summary || appName || "notification",
            kind: appName || "",
        }
    }

    function buildItems(tracked, history) {
        const out = []
        const vals = (tracked && tracked.values) ? tracked.values : []
        const activeSummaries = {}

        if (vals.length > 0) {
            out.push({ divider: true, label: "current" })
            for (let i = 0; i < vals.length; i++) {
                const n = vals[i]
                activeSummaries[n.summary || ""] = true
                const wid = (n.hints && n.hints["niri-window"] !== undefined) ? n.hints["niri-window"] : ""
                const e = entry(n.appName, n.summary, wid)
                e.notif = n
                out.push(e)
            }
        }

        const hist = history || []
        const seen = {}
        const histItems = []
        for (let i = 0; i < hist.length; i++) {
            const h = hist[i]
            const key = (h.appName || "") + " " + (h.summary || "")
            if (seen[key] || activeSummaries[h.summary || ""]) continue
            seen[key] = true
            histItems.push(entry(h.appName, h.summary, h.windowId))
        }
        if (histItems.length > 0) {
            out.push({ divider: true, label: vals.length > 0 ? "earlier" : "history" })
            for (let i = 0; i < histItems.length; i++) out.push(histItems[i])
        }
        return out
    }
}
