pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import "."

Singleton {
    id: root

    readonly property alias server: notifServer
    readonly property alias tracked: notifServer.trackedNotifications

    // Notifications are a persistent center: nothing auto-dismisses, so Super+i
    // always shows recent ones (and can re-fire their live action). Focusing a
    // notification's source marks it "seen" — it stays tracked but moves to the
    // picker's "earlier" group instead of vanishing. seenGen bumps on every
    // change so bindings that read seenIds re-evaluate.
    property var seenIds: ({})
    property int seenGen: 0
    // A genuinely-new notification passed every filter — fired once per
    // arrival for the island to animate.
    signal present(var notification)
    function markSeen(n) {
        if (n) root.markSeenById(n.id)
    }
    function markSeenById(id) {
        if (id !== undefined && !root.seenIds[id]) { root.seenIds[id] = true; root.seenGen++ }
    }
    function isSeen(n) {
        return !!(n && root.isSeenId(n.id))
    }
    function isSeenId(id) {
        const _ = root.seenGen
        // Not live = restored across a reload (keepOnReload); treat as seen so a
        // rebuild doesn't resurface already-read messages (seenIds resets on reload).
        if (id !== undefined && !root.liveIds[id]) return true
        return !!root.seenIds[id]
    }

    // Only a genuinely NEW notification — delivered via onNotification, which
    // marks it live below — presents. Notifications restored across a reload
    // (keepOnReload: rebuild, theme switch) are re-populated into
    // trackedNotifications WITHOUT re-firing onNotification, so they never
    // enter liveIds and stay quiet (they still live in the Super+i history).
    // This is timing-independent — unlike snapshotting trackedNotifications
    // at startup, which races the async restore and misses everything.
    property var liveIds: ({})
    function isLive(n) { return !!(n && root.liveIds[n.id]) }

    // Backstop for the edge where a restore somehow re-fires onNotification:
    // suppress presentation for a short settle window after launch.
    property bool startupSettled: false
    Timer {
        running: true
        interval: 1500
        onTriggered: root.startupSettled = true
    }

    // Opening a message's channel fires its default action, and quickshell
    // deletes a notification the instant its action is invoked. To keep the
    // Super+i center a real history, we retain a message's display data at that
    // moment; the picker shows tracked (live) ∪ retained. Claude is never
    // retained — it's meant to clear on interact.
    property var retained: []      // newest-first: {id, app, summary, windowId}
    property int retainedGen: 0
    function retain(id, app, summary, windowId) {
        if (id === undefined) return
        root.retained = root.retained.filter(e => e.id !== id)
        root.retained.unshift({ id: id, app: app || "", summary: summary || "", windowId: windowId || "" })
        if (root.retained.length > root.messageMax)
            root.retained = root.retained.slice(0, root.messageMax)
        root.retainedGen++
    }

    // Only these apps persist in the Super+i tray. Everything else (screenshots,
    // system notify-send, etc.) still shows once in the island — which dismisses
    // it after — so the center stays a list of things you can actually act on.
    // Which notification id is showing in the island right now, reported by
    // NotificationIsland. Lets Super+i jump straight to a lone on-screen one.
    property var visibleToastIds: ({})
    function setToastVisible(id, vis) {
        if (id === undefined || id === null || id === 0) return
        const m = root.visibleToastIds
        if (!!m[id] === !!vis) return
        if (vis) m[id] = true; else delete m[id]
        root.visibleToastIds = m
    }
    function visibleTrayToasts() {
        const out = []
        const all = notifServer.trackedNotifications.values
        for (let i = 0; i < all.length; i++)
            if (root.visibleToastIds[all[i].id] && root.isTrayApp(all[i])) out.push(all[i])
        return out
    }

    // Brand glyph for an app's notifications (white-fill SVGs under assets/,
    // tinted by the consumer). Used by both the Super+i picker and the island's
    // no-avatar fallback.
    function appIconFor(appName, appIcon) {
        // A notification's own icon can override the per-app brand glyph —
        // mlqs sends x-office-calendar for meeting reminders so they don't
        // wear the mail icon.
        if ((appIcon || "") === "x-office-calendar") return Qt.resolvedUrl("../assets/calendar.svg")
        const a = (appName || "").toLowerCase()
        if (a === "slack" || a === "slqs") return Qt.resolvedUrl("../assets/slack.svg")
        if (a === "discord" || a === "dsqrd") return Qt.resolvedUrl("../assets/discord.svg")
        if (a === "mlqs") return Qt.resolvedUrl("../assets/mail.svg")
        if (a === "kitty") return Qt.resolvedUrl("../assets/claude.svg")
        if (a === "screenshot") return Qt.resolvedUrl("../assets/camera.svg")
        return ""
    }

    readonly property var trayApps: ["slack", "discord", "kitty", "mlqs"]
    function isTrayApp(n) {
        return !!(n && root.trayApps.indexOf((n.appName || "").toLowerCase()) !== -1)
    }
    // Slack/Discord messages are durable history: kept across "seen", never
    // cleared on focus, bounded only by messageMax. Claude (kitty) prompts are
    // transient — cleared the moment you act on the session that raised them.
    readonly property var messageApps: ["slack", "discord", "mlqs"]
    function isMessageApp(n) {
        return !!(n && root.isMessageAppName(n.appName))
    }
    function isMessageAppName(app) {
        return root.messageApps.indexOf((app || "").toLowerCase()) !== -1
    }
    function clearOne(n) {
        if (n) { delete root.seenIds[n.id]; n.dismiss() }
    }

    // Drop older tracked notifications sharing this one's app + summary, so the
    // center keeps a single (latest) entry per channel / Claude session instead
    // of a stack of them.
    function _dropDuplicatesOf(n) {
        if (!n) return
        const app = n.appName || ""
        const sum = n.summary || ""
        const all = notifServer.trackedNotifications.values.slice()
        for (let i = 0; i < all.length; i++) {
            const o = all[i]
            if (!o || o.id === n.id) continue
            if ((o.appName || "") === app && (o.summary || "") === sum) {
                delete root.seenIds[o.id]
                o.dismiss()
            }
        }
    }

    // Conversation key for a message notification: the channel/group/DM it came
    // from, not the sender. dsqrd/slqs summaries are "author in #channel",
    // "author in GroupName", or just "person" (1:1 DM) — so the part after the
    // last " in " is the conversation, else the whole summary.
    function _convKey(app, summary) {
        const m = (summary || "").match(/^.* in (.+)$/)
        const conv = m ? m[1] : (summary || "")
        return (app || "").toLowerCase() + "|" + conv
    }

    // One entry per conversation: a new message supersedes earlier ones from the
    // same channel/group/DM (whoever sent them), dropping both the live tracked
    // copies and any retained (already-opened) entry, so the center shows just
    // the latest line per conversation.
    function _collapseConversation(n) {
        if (!n) return
        const key = root._convKey(n.appName, n.summary)
        const all = notifServer.trackedNotifications.values.slice()
        for (let i = 0; i < all.length; i++) {
            const o = all[i]
            if (!o || o.id === n.id) continue
            if (root.isMessageApp(o) && root._convKey(o.appName, o.summary) === key) {
                delete root.seenIds[o.id]
                o.dismiss()
            }
        }
        const before = root.retained.length
        root.retained = root.retained.filter(e => root._convKey(e.app, e.summary) !== key)
        if (root.retained.length !== before) root.retainedGen++
    }

    // Keep the most recent messageMax Slack/Discord messages as history (seen or
    // not). Claude prompts clear on interact and non-tray notifs drop after their
    // toast, so only messages accumulate here.
    readonly property int messageMax: 30
    function enforceCap() {
        const msgs = notifServer.trackedNotifications.values.filter(n => root.isMessageApp(n))
        if (msgs.length <= root.messageMax) return
        msgs.sort((a, b) => (a.id || 0) - (b.id || 0))   // oldest first
        for (let i = 0; i < msgs.length - root.messageMax; i++) {
            delete root.seenIds[msgs[i].id]
            msgs[i].dismiss()
        }
    }

    // Focused app_id (or org.quickshell window title) → the notification
    // appNames it "covers". Focusing the Slack client clears its "Slack"
    // notifications; the native clients share app_id org.quickshell and are
    // keyed by window title (slqs's window is titled "slqs"; it emits "Slack").
    readonly property var focusedAppCovers: ({
        "Slack":          ["slack"],
        "claude":         ["kitty"],
        "kitty":          ["kitty"],
        "discord-client": ["discord"],
        "slqs":           ["slack"],
        "mail-client":    ["mlqs"]
    })

    readonly property string focusedApp: {
        const _ = NiriState.version
        const app = NiriState.focusedAppId()
        // slqs/dsqrd are both org.quickshell; tell them apart by window title.
        if (app === "org.quickshell") {
            const t = NiriState.focusedTitle()
            if (t === "discord-client" || t === "slqs" || t === "mail-client") return t
        }
        return app
    }
    readonly property string focusedWs: {
        const _ = NiriState.version
        return NiriState.focusedWorkspaceName()
    }
    // The focused window id is included so moving between Claude windows (even
    // on the same workspace) re-runs the clear pass; the kitty match keys off
    // each notification's niri-window hint, so it must track window focus.
    readonly property string focusedKey: {
        const _ = NiriState.version
        return focusedApp + " " + focusedWs + " " + NiriState.focusedWindowId()
    }

    // True when the notification's source is the window you're focused on. For
    // kitty/Claude that means the focused niri window is the one that raised it
    // (matched via the niri-window hint set by notify-with-context.sh), so
    // focusing any Claude session clears its own prompt.
    function _matchesFocus(notification) {
        const covers = focusedAppCovers[focusedApp]
        if (!covers) return false
        const a = (notification.appName || "").toLowerCase()
        if (covers.indexOf(a) === -1) return false
        if (a === "kitty") {
            const hints = notification.hints || ({})
            const hint = (hints["niri-window"] !== undefined) ? String(hints["niri-window"]) : ""
            if (!hint || hint !== String(NiriState.focusedWindowId())) return false
        }
        return true
    }

    onFocusedKeyChanged: {
        if (!focusedAppCovers[focusedApp]) return
        const all = notifServer.trackedNotifications.values.slice()
        for (let i = 0; i < all.length; i++) {
            if (!_matchesFocus(all[i])) continue
            // Messages survive as history (just marked read); Claude prompts
            // clear the moment you focus the session that raised them.
            if (root.isMessageApp(all[i])) root.markSeen(all[i])
            else root.clearOne(all[i])
        }
    }

    NotificationServer {
        id: notifServer
        keepOnReload: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: true
        imageSupported: true
        actionsSupported: true

        onNotification: notification => {
            if (DndState.active && notification.urgency !== NotificationUrgency.Critical) {
                notification.dismiss()
                return
            }
            // Claude Code fires a generic "Claude Code" notification on every
            // Notification event; our notify-with-context.sh hook fires a
            // worktree-tagged "Claude · <label>" replacement for the same
            // event. Drop the generic one so exactly one shows. (Was a mako
            // rule until the notification daemon moved into quickshell.)
            if ((notification.appName || "").toLowerCase() === "kitty"
                    && (notification.summary || "") === "Claude Code") {
                notification.dismiss()
                return
            }
            delete root.seenIds[notification.id]
            root.liveIds[notification.id] = true
            notification.tracked = true
            // Arrivals during the post-reload settle window are restores re-fired
            // by keepOnReload, not genuinely new — mark them seen so they land in
            // "earlier"/off the badge (same startupSettled gate as presentation).
            if (!root.startupSettled) root.markSeenById(notification.id)
            // One entry per source. Messages collapse by conversation (the
            // channel/group/DM — latest line wins, regardless of sender); Claude
            // collapses by session (latest prompt).
            if (root.isMessageApp(notification))
                root._collapseConversation(notification)
            else if (root.isTrayApp(notification))
                root._dropDuplicatesOf(notification)
            // A Claude prompt arriving on the session you're focused on just
            // clears. Messages are NOT suppressed here: slqs/dsqrd already
            // withhold the channel you're actually viewing (should=false), so
            // anything that reaches us is a different channel and should
            // present even while the client window is focused.
            if (root._matchesFocus(notification) && !root.isMessageApp(notification)) {
                root.clearOne(notification)
                return
            }
            root.enforceCap()
            // The island presents anything that got this far and isn't a
            // keepOnReload restore.
            if (root.startupSettled) root.present(notification)
        }
    }

    function _findById(id) {
        const num = parseInt(id)
        const all = notifServer.trackedNotifications.values
        for (let i = 0; i < all.length; i++) if (all[i].id === num) return all[i]
        return null
    }

    IpcHandler {
        target: "notifications"

        function list(): string {
            const all = notifServer.trackedNotifications.values
            const out = []
            for (let i = 0; i < all.length; i++) {
                const n = all[i]
                out.push({
                    id: n.id,
                    app_name: n.appName,
                    summary: n.summary,
                    body: n.body,
                    desktop_entry: n.desktopEntry || "",
                    app_icon: n.appIcon || "",
                    hints: n.hints || {},
                    actions: (n.actions || []).map(a => ({ id: a.identifier, name: a.text }))
                })
            }
            return JSON.stringify(out)
        }

        function invoke(id: string): string {
            const n = root._findById(id)
            if (!n) return "no-such-notification"
            const actions = n.actions || []
            for (let i = 0; i < actions.length; i++) {
                if (actions[i].identifier === "default" || actions[i].name === "default") {
                    actions[i].invoke()
                    return "invoked"
                }
            }
            if (actions.length > 0) {
                actions[0].invoke()
                return "invoked-first"
            }
            return "no-actions"
        }

        function dismiss(id: string): string {
            const n = root._findById(id)
            if (!n) return "no-such-notification"
            n.dismiss()
            return "dismissed"
        }

        function dismissAll(): string {
            const all = notifServer.trackedNotifications.values.slice()
            for (let i = 0; i < all.length; i++) all[i].dismiss()
            return "dismissed " + all.length
        }
    }
}
