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
    altLabel: "Enter: copy"

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
        return {
            label: firstLine.length > 0 ? firstLine : "(whitespace)",
            sub: (e.pinned ? "pinned · " : "") + String(e.recorded || "").split(".")[0],
            icon: isImg ? "file://" + e.filePath : "",
            value: e.value,
            filePath: isImg ? e.filePath : "",
        }
    })

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
