import QtQuick
import Quickshell
import Quickshell.Io
import "."

Picker {
    id: root

    open: WorktreeCreatePickerState.open
    onCloseRequested: WorktreeCreatePickerState.open = false

    placeholder: "workspace"
    altLabel: "Enter: open / create / resume    Ctrl+W: close worktree"
    subtitleField: "kind"
    glyphField: "glyph"
    glyphColorField: "gcolor"
    highlightField: "active"
    altKey: Qt.Key_W

    // Closed worktrees + LoL sandboxes available to resume (respawn the
    // stack). Reloaded each open from ws-startwt --json so the listing
    // logic lives in one place.
    property var resumable: []
    onActiveChanged: if (active) resumeProc.running = true

    items: buildItems(NiriState.version, namesFile.labels, NiriState.activeStack, root.resumable)

    onEnter: item => {
        if (!item) return
        if (item.action === "create-local") {
            WorktreeCreatePickerState.open = false
            WorktreeNameInputPickerState.show("local")
            return
        }
        if (item.action === "create-lol") {
            WorktreeCreatePickerState.open = false
            WorktreeNameInputPickerState.show("lol")
            return
        }
        if (item.action === "resume-wt") {
            WorktreeCreatePickerState.open = false
            Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-createwt", item.name])
            return
        }
        if (item.action === "resume-lol") {
            WorktreeCreatePickerState.open = false
            Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-createlovbox", item.name, item.target])
            return
        }
        Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-jump-adjacent", "lovable-" + item.name])
    }

    onAltAction: item => {
        if (!item || item.action) return
        Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-close-worktree", item.name])
    }

    Process {
        id: resumeProc
        command: [Quickshell.env("HOME") + "/.config/niri/scripts/ws-startwt", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.resumable = JSON.parse(this.text || "[]") }
                catch (e) { root.resumable = [] }
            }
        }
    }

    FileView {
        id: namesFile
        path: Quickshell.env("HOME") + "/.local/state/lovssh/names.json"
        watchChanges: true
        onFileChanged: reload()

        property var labels: ({})
        onLoaded: {
            try { labels = JSON.parse(text() || "{}") } catch (e) { labels = {} }
        }
        onLoadFailed: labels = ({})
    }

    function buildItems(_version, lovboxLabels, activeStack, resumable) {
        const _ = _version
        const lolNames = {}
        for (const claim in lovboxLabels) lolNames[lovboxLabels[claim]] = true

        const openSet = {}
        const existing = []
        const wsMap = NiriState.workspaces
        for (const id in wsMap) {
            const n = wsMap[id].name || ""
            if (!n.startsWith("lovable-")) continue
            if (n === "lovable" || n === "lovable-main") continue
            const bare = n.substring("lovable-".length)
            existing.push(bare)
            openSet[bare] = true
        }

        const activeBare = (activeStack || "").replace(/^lovable-/, "")
        // Actions read as actions: accent "+" glyph, plain title, a subtitle
        // that says what happens — not a cryptic WT/LoL tag.
        const create = [
            { action: "create-local", label: "Create local worktree", glyph: "+", gcolor: Theme.cursor,
              kind: "branch + worktree + window stack" },
            { action: "create-lol",   label: "Create Lovable-on-Lovable", glyph: "+", gcolor: Theme.cursor,
              kind: "remote sandbox project" },
        ]
        // WT is the default — only remote sandboxes earn a subtitle.
        const wsItems = existing.map(n => ({
            name: n,
            label: n,
            kind: lolNames[n] ? "remote sandbox" : "",
            active: n === activeBare,
        }))

        // Resume entries: on-disk worktrees / sandboxes that aren't open
        // (open ones already appear above as jump targets). Capped to the
        // most-recent few — the full backlog lives in Super+Ctrl+T.
        const resumeItems = []
        const seen = {}
        const list = resumable || []
        for (let i = 0; i < list.length && resumeItems.length < 8; i++) {
            const r = list[i]
            const n = r.name || ""
            if (!n || n === "main" || openSet[n] || seen[n]) continue
            seen[n] = true
            resumeItems.push({
                action: r.kind === "lol" ? "resume-lol" : "resume-wt",
                name: n,
                target: r.target || "",
                label: n,
                kind: r.kind === "lol" ? "remote sandbox" : "",
            })
        }

        let out = [{ divider: true, label: "create" }].concat(create)
        if (wsItems.length) {
            out.push({ divider: true, label: "open" })
            out = out.concat(wsItems)
        }
        if (resumeItems.length) {
            out.push({ divider: true, label: "resume" })
            out = out.concat(resumeItems)
        }
        return out
    }
}
