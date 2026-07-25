pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Cockpit contexts and their agent activity. Contexts are the tabs of the
// cockpit's agent kitty (the engine's public surface: a control socket per
// window); the active one comes from the state file cockpit-switch owns.
// Feeds CockpitPicker and CockpitChips.
Singleton {
    id: root

    readonly property string scripts: Quickshell.env("HOME") + "/.config/niri/scripts/"

    // [{name, state}] — state is "working" | "awaiting-you" | "idle".
    property var contexts: []
    property string active: ""

    property bool open: false

    // Instance knowledge the chrome is allowed to have (see plan): the niri
    // workspace the cockpit lives on.
    readonly property string workspace: "lovable"

    function toggle() {
        open = !open
        if (open)
            Quickshell.execDetached(["niri", "msg", "action", "focus-workspace", workspace])
    }

    IpcHandler {
        target: "cockpit"
        function toggle() { root.toggle() }
        function show()   { root.open = true }
        function hide()   { root.open = false }
        function dump(): string {
            return JSON.stringify(root.contexts) + " active=" + root.active
        }
    }

    function switchTo(name) {
        Quickshell.execDetached([scripts + "cockpit-switch", name])
        // Optimistic: the FileView watch confirms, but chips/picker must flip
        // with the tabs, not a disk round-trip later.
        active = name
    }

    function add(name) {
        Quickshell.execDetached([scripts + "cockpit-add", name])
    }

    // Closes the context's tabs in every cockpit window; the directory on disk
    // is deliberately kept (removing a worktree is `wt remove`, not a UI gesture).
    function close(name) {
        Quickshell.execDetached(["bash", "-c",
            'source "$HOME/.config/cockpit/config"; ' +
            'for w in "${COCKPIT_WINDOWS[@]}"; do ' +
            '  s="/tmp/kitty-cockpit-$w"; [ -S "$s" ] || continue; ' +
            '  kitty @ --to "unix:$s" close-tab --match "title:^$1\\$" 2>/dev/null; ' +
            'done; ' +
            'f="${COCKPIT_STATE_DIR:-$HOME/.local/state/cockpit}/contexts"; ' +
            '[ -f "$f" ] && { grep -vxF "$1" "$f" > "$f.tmp"; mv "$f.tmp" "$f"; }',
            "_", name])
        refresh()
    }

    function refresh() {
        if (probe.running) return
        probe.running = true
    }

    onActiveChanged: refresh()

    // Contexts + their activity glyph come from the instance config's
    // cockpit_context_states (tab titles from the agent window's control
    // socket, each scored off its newest non-empty transcript).
    Process {
        id: probe
        running: true
        command: ["bash", "-c",
            'source "$HOME/.config/cockpit/config" 2>/dev/null || exit 0; cockpit_context_states']

        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                for (const line of text.trim().split("\n")) {
                    if (!line) continue
                    const parts = line.split("\t")
                    out.push({ name: parts[0], state: parts[1] || "idle" })
                }
                root.contexts = out
            }
        }
    }

    // Cheap enough to poll: one kitty roundtrip plus a stat per context. Keeps
    // the glyphs honest while an agent works without any push plumbing.
    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/cockpit/active"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.active = text().trim()
        onLoadFailed: root.active = ""
    }
}
