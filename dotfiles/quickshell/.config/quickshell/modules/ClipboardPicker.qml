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
    previewTextField: "value"
    thumbSize: 56
    enterLabel: "copy"
    ctrlEnterAlt: true
    altLabel: "Ctrl+Enter: open   ·   Ctrl+O: preview   ·   Ctrl+W: delete"
    categoryField: "cat"
    categories: [{ key: "all", label: "All" }, { key: "image", label: "Images" },
                 { key: "link", label: "Links" }, { key: "color", label: "Colors" }]

    // A hex color recognized for the color category + its swatch-tinted badge.
    // "rgb(...)" strings still classify as color but tint the badge cyan.
    readonly property var _hexRe: /^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i
    function _isColor(s) {
        return root._hexRe.test(s) || /^(rgb|rgba|hsl|hsla)\(/i.test(s)
    }

    // clipse can't tell a screenshot from a pasted image, but both niri's
    // built-in screenshots (~/Pictures/Screenshots) and the selection script
    // (/tmp/screenshot-*) leave a datestamped file. Scan their mtimes on open;
    // an image whose recorded time matches one (±4s) was screenshotted.
    property var shotTimes: []
    Process {
        id: shotScan
        running: root.open
        command: ["bash", "-c",
            "stat -c %Y \"$HOME\"/Pictures/Screenshots/*.png /tmp/screenshot-*.png 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                for (const l of (this.text || "").split("\n")) {
                    const n = parseInt(l.trim())
                    if (!isNaN(n)) out.push(n)
                }
                root.shotTimes = out
            }
        }
    }
    function _recEpoch(rec) {
        const s = String(rec || "")
        if (s.length < 19) return 0
        return new Date(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10),
                        +s.slice(11, 13), +s.slice(14, 16), +s.slice(17, 19)).getTime() / 1000
    }
    function _isShot(rec) {
        const t = root._recEpoch(rec)
        for (let i = 0; i < shotTimes.length; i++)
            if (Math.abs(shotTimes[i] - t) <= 4) return true
        return false
    }

    function _ymd(d) {
        const m = String(d.getMonth() + 1).padStart(2, "0")
        const day = String(d.getDate()).padStart(2, "0")
        return d.getFullYear() + "-" + m + "-" + day
    }
    // "today 10:44" / "yesterday 10:44" / "2026-07-05 10:44" for older. clipse
    // records local time as "YYYY-MM-DD HH:MM:SS.fff".
    function _relTime(rec) {
        const s = String(rec || "")
        if (s.length < 16) return s
        const datePart = s.slice(0, 10)
        const timePart = s.slice(11, 16)
        const now = new Date()
        if (datePart === root._ymd(now)) return "today " + timePart
        if (datePart === root._ymd(new Date(now.getTime() - 86400000))) return "yesterday " + timePart
        return datePart + " " + timePart
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
        const shot = isImg && generated && root._isShot(e.recorded)
        const isColor = !isImg && root._isColor(firstLine)
        const isLink = !isImg && /^https?:\/\/\S+$/i.test(firstLine)
        // cat stays "image" for screenshots too, so the Images filter groups both;
        // the badge/label carry the screenshot-vs-image distinction.
        const cat = isImg ? "image" : (isLink ? "link" : (isColor ? "color" : "text"))
        const badge = isImg ? (shot ? "screenshot" : "image")
                    : (cat === "text" ? "" : cat)
        const label = isImg ? (generated ? (shot ? "Screenshot" : "Image") : base)
                    : (firstLine.length > 0 ? firstLine : "(whitespace)")
        // Category badge colors from the theme palette — the muted accents
        // (blue/purple/pink) read alike, so use the distinct hues: sky for
        // links, green for images. A color entry tints to its own swatch.
        const badgeColor = cat === "image" ? Theme.green
                         : cat === "link" ? Theme.sky
                         : cat === "color" ? (root._hexRe.test(firstLine) ? firstLine : Theme.cyan)
                         : ""
        return {
            label: label,
            sub: (e.pinned ? "pinned · " : "") + root._relTime(e.recorded),
            icon: isImg ? "file://" + e.filePath : "",
            badge: badge,
            badgeColor: badgeColor,
            value: e.value,
            filePath: isImg ? e.filePath : "",
            recorded: e.recorded,
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

    // Ctrl+W: drop the entry from clipse's store. Optimistic in-memory update
    // for instant feedback; the file rewrite (matched on the unique recorded
    // timestamp) is the source of truth and re-syncs via watchChanges.
    onDelete: item => {
        if (!item || !item.recorded) return
        histFile.entries = histFile.entries.filter(e => e.recorded !== item.recorded)
        Quickshell.execDetached(["python3", "-c",
            "import json,sys,os\n" +
            "p=os.path.expanduser('~/.config/clipse/clipboard_history.json')\n" +
            "d=json.load(open(p))\n" +
            "d['clipboardHistory']=[e for e in d.get('clipboardHistory',[]) if e.get('recorded')!=sys.argv[1]]\n" +
            "t=p+'.tmp'; json.dump(d,open(t,'w')); os.replace(t,p)\n",
            String(item.recorded)])
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
