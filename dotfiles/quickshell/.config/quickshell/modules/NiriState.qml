pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "."

// Subscribes to niri's event stream once; mirrors workspaces + windows
// state in JS dicts. Consumers bind to derived helpers (minimapEntries,
// visibleWorkspaces) which include `version` to force re-evaluation on
// every relevant event (deep-mutating a `property var` doesn't trigger
// QML bindings on its own).
Singleton {
    id: state

    property var workspaces: ({})
    property var windows: ({})
    property string activeStack: ""
    property int version: 0

    readonly property var relevantEvents: [
        "WorkspacesChanged",
        "WindowsChanged",
        "WorkspaceActivated",
        "WorkspaceActiveWindowChanged",
        "WindowOpenedOrChanged",
        "WindowClosed",
        "WindowFocusChanged",
        "WindowLayoutsChanged",
    ]

    FileView {
        id: activeStackFile
        path: Quickshell.env("HOME") + "/.local/state/wt-stacks/ws/active"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            state.activeStack = (text() || "").trim()
            state.version += 1
        }
    }

    Process {
        id: eventStream
        command: ["niri", "msg", "--json", "event-stream"]
        running: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => state._handleEventLine(line)
        }

        onExited: (exitCode, exitStatus) => restartTimer.start()
    }

    Timer {
        id: restartTimer
        interval: 1000
        repeat: false
        onTriggered: eventStream.running = true
    }

    function _handleEventLine(line) {
        const trimmed = line.trim()
        if (!trimmed) return
        let event
        try { event = JSON.parse(trimmed) } catch (e) { return }
        if (!event || typeof event !== "object") return
        const keys = Object.keys(event)
        if (keys.length !== 1) return
        const name = keys[0]
        const data = event[name]
        if (!data || typeof data !== "object") return

        _applyEvent(name, data)
        if (relevantEvents.indexOf(name) >= 0) state.version += 1
    }

    function _applyEvent(name, data) {
        if (name === "WorkspacesChanged") {
            const next = {}
            for (const w of (data.workspaces || [])) next[w.id] = w
            workspaces = next
        } else if (name === "WindowsChanged") {
            const next = {}
            for (const w of (data.windows || [])) next[w.id] = w
            windows = next
        } else if (name === "WorkspaceActivated") {
            const wsId = data.id
            const focused = data.focused || false
            const target = workspaces[wsId]
            if (!target) return
            const targetOutput = target.output
            for (const id in workspaces) {
                const w = workspaces[id]
                if (w.output === targetOutput) w.is_active = (w.id === wsId)
                if (focused) w.is_focused = (w.id === wsId)
            }
        } else if (name === "WorkspaceActiveWindowChanged") {
            const wsId = data.workspace_id
            if (workspaces[wsId]) workspaces[wsId].active_window_id = data.active_window_id
        } else if (name === "WindowOpenedOrChanged") {
            const w = data.window
            if (!w) return
            windows[w.id] = w
            if (w.is_focused) {
                for (const id in windows) {
                    if (windows[id].id !== w.id) windows[id].is_focused = false
                }
            }
        } else if (name === "WindowClosed") {
            delete windows[data.id]
        } else if (name === "WindowFocusChanged") {
            const focusedId = data.id
            for (const id in windows) {
                windows[id].is_focused = (windows[id].id === focusedId)
            }
        } else if (name === "WindowLayoutsChanged") {
            for (const change of (data.changes || [])) {
                const wid = change[0], layout = change[1]
                if (windows[wid]) windows[wid].layout = layout
            }
        }
    }

    // Mirrors waybar's is_hidden_workspace: hide `lovable-*` workspaces
    // except the currently-active stack (and the two shared persistent ones).
    function isHiddenWorkspace(ws) {
        const name = ws.name || ""
        if (!name.startsWith("lovable-")) return false
        if (name === "lovable" || name === "lovable-deps") return false
        // The couple (main + active worktree) is the visible unit — only
        // the inactive pile hides from the minimap.
        if (name === "lovable-main") return false
        return name !== activeStack
    }

    function minimapEntries(output) {
        const _ = version
        const out = []
        const groups = visibleWorkspaces(output)
        for (let g = 0; g < groups.length; g++) {
            const ws = groups[g].ws
            const wins = groups[g].windows
            const activeId = ws.active_window_id
            const wsFocused = ws.is_focused || false
            const cells = []
            if (wins.length === 0 && (wsFocused || ws.is_active === true)) {
                cells.push({ kind: "dot" })
            } else {
                for (const w of wins) {
                    cells.push({
                        kind: "bar",
                        focused: w.is_focused === true,
                        wsActive: !wsFocused && w.id === activeId,
                    })
                }
            }
            // Gap only between groups that actually render — an empty
            // inactive workspace (niri's trailing one) used to leave a
            // phantom gap cell that pushed the ticks ~9px off center.
            if (cells.length === 0) continue
            if (out.length > 0) out.push({ kind: "gap" })
            for (const c of cells) out.push(c)
        }
        return out
    }

    function focusedAppId() {
        const _ = version
        for (const id in windows) {
            if (windows[id].is_focused) return windows[id].app_id || ""
        }
        return ""
    }

    function focusedWorkspaceName() {
        const _ = version
        for (const id in workspaces) {
            if (workspaces[id].is_focused) return workspaces[id].name || ""
        }
        return ""
    }

    // The workspace currently VISIBLE on a given output — per-monitor state,
    // unlike focusedWorkspaceName() which is global (per-screen bars must not
    // mirror the other monitor's badge).
    function activeWorkspaceName(output) {
        const _ = version
        for (const id in workspaces) {
            const ws = workspaces[id]
            if (ws.output === output && ws.is_active) return ws.name || ""
        }
        return ""
    }

    function focusedTitle() {
        const _ = version
        for (const id in windows) {
            if (windows[id].is_focused) return windows[id].title || ""
        }
        return ""
    }

    function focusedWindowId() {
        const _ = version
        for (const id in windows) {
            if (windows[id].is_focused) return windows[id].id
        }
        return -1
    }

    // Focused window's rectangle within its output's workspace view, from
    // niri's IPC. Uses tile_pos + tile_size (the VISIBLE window box incl.
    // niri's border), not window_size (content only) — so the focus dot
    // centers under the window's real edges. Null when the running niri
    // doesn't report a position (tiled windows need the patched niri;
    // floating report it on any version); the dot stays hidden until non-null.
    function focusedWindowGeom() {
        const _ = version
        for (const id in windows) {
            const w = windows[id]
            if (!w.is_focused) continue
            const L = w.layout || {}
            const p = L.tile_pos_in_workspace_view
            const s = L.tile_size
            if (!p || !s) return null
            return { x: p[0], y: p[1], w: s[0], h: s[1], floating: w.is_floating === true }
        }
        return null
    }

    // niri's IPC carries no fullscreen state — only fullscreen *actions* — so
    // infer it: a fullscreen tile spans the whole output, while tiled windows
    // start below the bar's exclusive zone (y=60 with the bar, 16 without).
    // Deliberately tile_* and not window_size: a fixed-size fullscreen window
    // is centered on a black backdrop, so its surface stays smaller than the
    // output while its tile still covers it.
    // Same test against an arbitrary geometry, so a caller holding a frozen box
    // (e.g. while a layer-shell picker owns focus) still reads fullscreen right.
    function isFullscreenGeom(g, outputHeight) {
        return !!(g && outputHeight && g.y <= 1 && g.h >= outputHeight - 1)
    }

    function focusedIsFullscreen(outputHeight) {
        if (!outputHeight) return false
        const g = focusedWindowGeom()
        if (g) return isFullscreenGeom(g, outputHeight)
        // Unpatched niri reports no tile position for tiled windows. Fall back
        // to the surface size — misses the letterboxed case, but it is what the
        // island relied on before, so behaviour never regresses on old niri.
        const w = windows[focusedWindowId()]
        const s = w && w.layout && w.layout.window_size
        return s ? s[1] >= outputHeight : false
    }

    function focusedOutput() {
        const _ = version
        for (const id in workspaces) {
            if (workspaces[id].is_focused) return workspaces[id].output || ""
        }
        return ""
    }

    function visibleWorkspaces(output) {
        const _ = version
        const result = []
        const wsWindows = {}
        for (const id in windows) {
            const w = windows[id]
            const wsId = w.workspace_id
            if (!wsWindows[wsId]) wsWindows[wsId] = []
            wsWindows[wsId].push(w)
        }
        const wsList = []
        for (const id in workspaces) {
            const ws = workspaces[id]
            if (isHiddenWorkspace(ws)) continue
            if (output && ws.output !== output) continue
            wsList.push(ws)
        }
        wsList.sort((a, b) => {
            const oa = a.output || "", ob = b.output || ""
            if (oa !== ob) return oa < ob ? -1 : 1
            return a.idx - b.idx
        })
        for (const ws of wsList) {
            const wins = (wsWindows[ws.id] || []).slice()
            wins.sort((a, b) => {
                const ap = (a.layout || {}).pos_in_scrolling_layout
                const bp = (b.layout || {}).pos_in_scrolling_layout
                if (ap && bp) {
                    if (ap[0] !== bp[0]) return ap[0] - bp[0]
                    if (ap[1] !== bp[1]) return ap[1] - bp[1]
                }
                if (ap && !bp) return -1
                if (!ap && bp) return 1
                return a.id - b.id
            })
            result.push({ ws: ws, windows: wins })
        }
        return result
    }
}
