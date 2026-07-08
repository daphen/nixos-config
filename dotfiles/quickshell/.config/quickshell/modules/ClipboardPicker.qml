import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Clipboard history picker over clipse's store: the clipse listener keeps
// recording (`clipse -listen`); this replaces only its TUI. The history
// JSON is watched live, image entries render their thumbnail, Enter copies
// (text via wl-copy argv, images by mime from the file extension).
Picker {
    id: root

    open: ClipboardPickerState.open
    onCloseRequested: ClipboardPickerState.open = false

    placeholder: "clipboard history"
    subtitleField: "sub"
    iconField: "icon"
    badgeField: "badge"
    badgeColorField: "badgeColor"
    previewField: "filePath"
    enterLabel: "copy"
    ctrlEnterAlt: true
    altLabel: "Ctrl+Enter: open link / image   ·   Ctrl+O: preview"
    categoryField: "cat"
    categories: [{ key: "all", label: "All" }, { key: "image", label: "Images" },
                 { key: "link", label: "Links" }, { key: "color", label: "Colors" }]

    // A hex color recognized for the color category + its swatch-tinted badge.
    // "rgb(...)" strings still classify as color but tint the badge cyan.
    readonly property var _hexRe: /^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i
    function _isColor(s) {
        return root._hexRe.test(s) || /^(rgb|rgba|hsl|hsla)\(/i.test(s)
    }

    FileView {
        id: histFile
        path: Quickshell.env("HOME") + "/.config/clipse/clipboard_history.json"
        watchChanges: true
        onFileChanged: reload()
        property var entries: []
        onLoaded: {
            try {
                entries = (JSON.parse(text() || "{}").clipboardHistory) || []
            } catch (e) {
                entries = []
            }
        }
        onLoadFailed: entries = []
    }

    items: histFile.entries.map(e => {
        const isImg = e.filePath && e.filePath !== "null"
        const firstLine = String(e.value || "").trim().split("\n")[0]
        const base = isImg ? String(e.filePath).split("/").pop() : ""
        // clipse generates temp names (12345-678.png) for clipboard images — a
        // clean "Image" reads better. A copied file keeps a meaningful name, so
        // show that verbatim.
        const generated = /^\d+-\d+\.[a-z0-9]+$/i.test(base)
        const isColor = !isImg && root._isColor(firstLine)
        const isLink = !isImg && /^https?:\/\/\S+$/i.test(firstLine)
        const cat = isImg ? "image" : (isLink ? "link" : (isColor ? "color" : "text"))
        const label = isImg ? (generated ? "Image" : base)
                    : (firstLine.length > 0 ? firstLine : "(whitespace)")
        // Category badge colors come from the theme palette; a color entry's
        // badge tints to the actual copied color (its own swatch).
        const badgeColor = cat === "image" ? Theme.purple
                         : cat === "link" ? Theme.blue
                         : cat === "color" ? (root._hexRe.test(firstLine) ? firstLine : Theme.cyan)
                         : ""
        return {
            label: label,
            sub: (e.pinned ? "pinned · " : "") + String(e.recorded || "").slice(0, 16),
            icon: isImg ? "file://" + e.filePath : "",
            badge: cat === "text" ? "" : cat,
            badgeColor: badgeColor,
            value: e.value,
            filePath: isImg ? e.filePath : "",
            cat: cat,
        }
    })

    // Ctrl+Enter: open instead of copy — links route through
    // browser-dispatch (pattern-based profile routing), images open in imv.
    // Plain text has nothing to open; no-op.
    onAltAction: item => {
        if (!item) return
        if (item.filePath) {
            Quickshell.execDetached(["imv", item.filePath])
            ClipboardPickerState.open = false
            return
        }
        const v = String(item.value || "").trim()
        if (/^https?:\/\/\S+$/.test(v)) {
            Quickshell.execDetached([
                Quickshell.env("HOME") + "/.config/niri/scripts/browser-dispatch", v])
            ClipboardPickerState.open = false
        }
    }

    onEnter: item => {
        if (!item) return
        if (item.filePath) {
            const mime = item.filePath.toLowerCase().endsWith(".jpg")
                      || item.filePath.toLowerCase().endsWith(".jpeg") ? "image/jpeg" : "image/png"
            Quickshell.execDetached(["sh", "-c",
                "wl-copy -t " + mime + " < \"$1\"", "_", item.filePath])
        } else {
            Quickshell.execDetached(["wl-copy", "--", String(item.value)])
        }
    }
}
