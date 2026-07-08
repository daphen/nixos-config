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
    previewField: "filePath"
    enterLabel: "copy"
    ctrlEnterAlt: true
    altLabel: "Ctrl+Enter: open link / image   ·   Ctrl+O: preview"

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
        // clipse bakes "📷 <tempname>.png" into an image entry's value — the
        // thumbnail already shows what it is, so a clean "Image" label reads better.
        const label = isImg ? "Image"
                    : (firstLine.length > 0 ? firstLine : "(whitespace)")
        return {
            label: label,
            sub: (e.pinned ? "pinned · " : "") + String(e.recorded || "").split(".")[0],
            icon: isImg ? "file://" + e.filePath : "",
            value: e.value,
            filePath: isImg ? e.filePath : "",
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
