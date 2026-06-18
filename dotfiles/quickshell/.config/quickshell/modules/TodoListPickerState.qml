pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Permanent quick-todo list, backed by ~/.local/state/quickshell/todos.md.
// Kept OUT of the synced notes vault: a `notes-cli -pull` overwrites local
// vault files with the backend copy and silently reverted this list. FileView
// still reads + parses it live (nvim edits show up); mutations route through
// the `todos` helper.
Singleton {
    id: root

    property bool open: false
    property var items: [] // [{ text, done, line }]

    // Open (unfinished) count, for the bar pill. Recomputes when items change.
    readonly property int openCount: {
        let n = 0
        for (let i = 0; i < items.length; i++) if (!items[i].done) n++
        return n
    }

    readonly property string path:
        Quickshell.env("HOME") + "/.local/state/quickshell/todos.md"
    readonly property string script:
        Quickshell.env("HOME") + "/.config/quickshell/scripts/todos"

    function toggle() { open = !open }
    function show()   { open = true }
    function hide()   { open = false }

    function toggleItem(item) {
        if (!item || !item.line) return
        Quickshell.execDetached([script, "toggle", String(item.line)])
    }

    function addItem(text) {
        const t = (text || "").trim()
        if (t.length === 0) return
        Quickshell.execDetached([script, "add", t])
    }

    function removeItem(item) {
        if (!item || !item.line) return
        Quickshell.execDetached([script, "remove", String(item.line)])
    }

    function openInNvim() {
        Quickshell.execDetached([
            "env", "FS_MONITOR_DISABLED=1",
            "kitty", "--class", "notes_capture",
            "--working-directory", Quickshell.env("HOME") + "/.local/state/quickshell",
            "--", "nvim", root.path,
        ])
        root.open = false
    }

    function parse(text) {
        const out = []
        const lines = (text || "").split("\n")
        const re = /^\s*- \[([ xX])\]\s+(.*\S)\s*$/
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(re)
            if (m) out.push({ text: m[2], done: m[1].toLowerCase() === "x", line: i + 1 })
        }
        // Open items first, finished ones sink to the bottom (file order
        // preserved within each group; each item keeps its real line number).
        root.items = out.filter(it => !it.done).concat(out.filter(it => it.done))
    }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parse(text())
        onLoadFailed: root.items = []
    }

    IpcHandler {
        target: "todos"
        function toggle() { root.toggle() }
        function show()   { root.show() }
        function hide()   { root.hide() }
    }
}
