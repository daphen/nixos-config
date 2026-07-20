pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Countdown timers: state + expiry. The picker (TimerPicker) and the bar
// module (Timers) render this. Timers survive config reloads via
// ~/.local/state/quickshell/timers.json — end times are absolute epoch ms,
// so a reload (or a shell hiccup) can't stretch a timer.
//
//   qs ipc call timers toggle          — picker
//   qs ipc call timers start "5m tea"  — scriptable
Singleton {
    id: root

    property bool open: false
    property var items: []        // [{ label, end }] sorted by end (epoch ms)
    property real now: Date.now() // ticks while timers run; drives countdowns

    function toggle() { open = !open }
    function show()   { open = true }
    function hide()   { open = false }

    readonly property string path:
        Quickshell.env("HOME") + "/.local/state/quickshell/timers.json"

    // "5" (minutes) · "25m" · "90s" · "1h" · "1h10" · "1h10m" · "1:30" (h:mm),
    // anything after whitespace is the label. Returns {ms, label} or null.
    function parseSpec(s) {
        const sp = String(s).trim()
        const cut = sp.search(/\s/)
        const tok = (cut < 0 ? sp : sp.slice(0, cut)).toLowerCase()
        const label = cut < 0 ? "" : sp.slice(cut).trim()
        let m
        if ((m = tok.match(/^(\d+):(\d{1,2})$/)))        return { ms: (+m[1] * 3600 + +m[2] * 60) * 1000, label: label }
        if ((m = tok.match(/^(\d+)h(?:(\d+)m?)?$/)))     return { ms: (+m[1] * 3600 + +(m[2] || 0) * 60) * 1000, label: label }
        if ((m = tok.match(/^(\d+)m(?:in)?$/)))          return { ms: +m[1] * 60000, label: label }
        if ((m = tok.match(/^(\d+)s(?:ec)?$/)))          return { ms: +m[1] * 1000, label: label }
        if ((m = tok.match(/^(\d+)$/)))                  return { ms: +m[1] * 60000, label: label }
        return null
    }

    function add(ms, label) {
        if (!ms || ms <= 0) return
        const next = items.concat([{ label: label || "", end: Date.now() + ms }])
        next.sort((a, b) => a.end - b.end)
        items = next
        saveState()
    }

    function cancel(index) {
        if (index < 0 || index >= items.length) return
        const next = items.slice()
        next.splice(index, 1)
        items = next
        saveState()
    }

    // For countdown text: 42s → "0:42", 25m → "25:00", 90m → "1:30:00"
    function fmt(ms) {
        const t = Math.max(0, Math.ceil(ms / 1000))
        const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60
        const p = n => (n < 10 ? "0" : "") + n
        return h > 0 ? h + ":" + p(m) + ":" + p(s) : m + ":" + p(s)
    }

    Timer {
        interval: 500
        repeat: true
        running: root.items.length > 0
        onTriggered: {
            root.now = Date.now()
            const due = root.items.filter(t => t.end <= root.now)
            if (due.length === 0) return
            for (const t of due)
                Quickshell.execDetached(["notify-send", "-u", "critical", "-a", "Timer",
                    "Time's up" + (t.label ? ": " + t.label : ""), ""])
            root.items = root.items.filter(t => t.end > root.now)
            root.saveState()
        }
    }

    function saveState() {
        try { store.setText(JSON.stringify({ items: items })) } catch (e) {}
    }
    FileView {
        id: store
        path: root.path
        onLoaded: {
            try {
                const st = JSON.parse(store.text())
                // fire anything that expired while the shell was away
                const alive = (st.items || []).filter(t => t && t.end > Date.now())
                for (const t of (st.items || []).filter(t => t && t.end <= Date.now()))
                    Quickshell.execDetached(["notify-send", "-u", "critical", "-a", "Timer",
                        "Time's up" + (t.label ? ": " + t.label : ""), ""])
                alive.sort((a, b) => a.end - b.end)
                root.items = alive
                if (alive.length !== (st.items || []).length) root.saveState()
            } catch (e) {}
        }
    }

    IpcHandler {
        target: "timers"
        function toggle() { root.toggle() }
        function show()   { root.show() }
        function hide()   { root.hide() }
        function start(spec: string): string {
            const p = root.parseSpec(spec)
            if (!p) return "bad spec: " + spec
            root.add(p.ms, p.label)
            return "started " + root.fmt(p.ms) + (p.label ? " — " + p.label : "")
        }
    }
}
