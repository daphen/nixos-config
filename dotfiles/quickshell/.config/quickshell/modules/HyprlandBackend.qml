import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Item {
    id: state

    property int version: 0
    property string activeStack: ""
    property var canvasSnapshot: null
    property bool refreshAgain: false

    signal paletteGesture(string phase, real progress, real velocity, bool open)
    signal paletteTabCycle(int direction, bool commit)

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/wt-stacks/ws/active"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            state.activeStack = (text() || "").trim()
            state.version += 1
        }
    }

    Process {
        id: canvasQuery
        running: true
        command: ["sh", "-c", "printf '{\"clients\":'; hyprctl -j clients; printf ',\"monitors\":'; hyprctl -j monitors; printf ',\"workspaces\":'; hyprctl -j workspaces; printf '}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    state.canvasSnapshot = JSON.parse(text)
                    state.version += 1
                } catch (error) {
                    console.warn("Failed to read Hyprland canvas state:", error)
                }
            }
        }
        onExited: {
            if (state.refreshAgain) {
                state.refreshAgain = false
                refreshTimer.restart()
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: 40
        onTriggered: canvasQuery.running = true
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const relevant = ["openwindow", "closewindow", "movewindow", "workspace", "focusedmon", "createworkspace", "destroyworkspace", "activewindow", "activewindowv2", "fullscreen"]
            if (!event || relevant.indexOf(event.name) < 0) return
            if (canvasQuery.running) state.refreshAgain = true
            else refreshTimer.restart()
        }
    }


    function isHiddenWorkspace(ws) {
        const name = ws.name || ""
        if (!name.startsWith("lovable-")) return false
        if (name === "lovable" || name === "lovable-deps" || name === "lovable-main") return false
        return name !== activeStack
    }

    function objectFor(window) {
        return window ? (window.lastIpcObject || {}) : {}
    }

    function outputForWorkspace(workspace) {
        return workspace && workspace.monitor ? workspace.monitor.name : ""
    }

    function normalizedWindows(workspace) {
        const source = workspace && workspace.toplevels ? workspace.toplevels.values : []
        const centersX = []
        const centersY = []
        for (const window of source) {
            const object = objectFor(window)
            const at = object.at || [0, 0]
            const size = object.size || [1, 1]
            centersX.push(Number(at[0]) + Number(size[0]) / 2)
            centersY.push(Number(at[1]) + Number(size[1]) / 2)
        }
        const unique = values => {
            const sorted = values.slice().sort((a, b) => a - b)
            const result = []
            for (const value of sorted)
                if (result.length === 0 || Math.abs(value - result[result.length - 1]) > 10) result.push(value)
            return result
        }
        const columns = unique(centersX)
        const rows = unique(centersY)
        const result = []
        for (let index = 0; index < source.length; index++) {
            const window = source[index]
            const object = objectFor(window)
            const at = object.at || [0, 0]
            const size = object.size || [1, 1]
            const centerX = Number(at[0]) + Number(size[0]) / 2
            const centerY = Number(at[1]) + Number(size[1]) / 2
            let column = columns.findIndex(value => Math.abs(value - centerX) <= 10)
            let row = rows.findIndex(value => Math.abs(value - centerY) <= 10)
            if (column < 0) column = index
            if (row < 0) row = 0
            result.push({
                id: window.address || String(index),
                app_id: object.class || object.initialClass || "",
                title: window.title || object.title || "",
                is_focused: window.activated === true,
                is_floating: object.floating === true,
                workspace_id: workspace.id,
                fullscreen: Number(object.fullscreen || 0) === 2
                    || Number(object.fullscreenClient || 0) === 2,
                layout: {
                    pos_in_scrolling_layout: [column + 1, row + 1],
                    canvas_row: row,
                    tile_pos_in_workspace_view: at,
                    tile_size: size,
                    window_size: size,
                },
            })
        }
        result.sort((a, b) => {
            const ap = a.layout.pos_in_scrolling_layout
            const bp = b.layout.pos_in_scrolling_layout
            return ap[0] === bp[0] ? ap[1] - bp[1] : ap[0] - bp[0]
        })
        return result
    }

    function normalizedWorkspace(workspace) {
        const windows = normalizedWindows(workspace)
        const active = windows.find(window => window.is_focused)
        return {
            id: workspace.id,
            idx: workspace.id,
            name: workspace.name || String(workspace.id),
            output: outputForWorkspace(workspace),
            is_active: workspace.active === true,
            is_focused: workspace.focused === true,
            active_window_id: active ? active.id : null,
        }
    }

    function canvasWorkspaces(output) {
        const snapshot = canvasSnapshot
        if (!snapshot) return []
        const monitors = {}
        for (const monitor of (snapshot.monitors || [])) monitors[monitor.id] = monitor
        const workspaceState = {}
        for (const workspace of (snapshot.workspaces || [])) workspaceState[workspace.name] = workspace
        const grouped = {}
        for (const client of (snapshot.clients || [])) {
            if (client.mapped === false || client.hidden === true) continue
            const monitor = monitors[client.monitor]
            const monitorName = monitor ? monitor.name : ""
            if (output && monitorName !== output) continue
            const workspaceName = client.workspace ? client.workspace.name : ""
            const key = monitorName + "\n" + workspaceName
            if (!grouped[key]) grouped[key] = { monitor: monitor, name: workspaceName, clients: [] }
            grouped[key].clients.push(client)
        }
        const result = []
        for (const key of Object.keys(grouped)) {
            const group = grouped[key]
            const centersY = group.clients.map(client => Number(client.at[1]) + Number(client.size[1]) / 2)
            const sortedY = centersY.slice().sort((a, b) => a - b)
            const rows = []
            for (const value of sortedY)
                if (rows.length === 0 || Math.abs(value - rows[rows.length - 1]) > 10) rows.push(value)
            const clientsByRow = {}
            for (const client of group.clients) {
                const centerY = Number(client.at[1]) + Number(client.size[1]) / 2
                const row = rows.findIndex(value => Math.abs(value - centerY) <= 10)
                if (!clientsByRow[row]) clientsByRow[row] = []
                clientsByRow[row].push(client)
            }
            const windowsByRow = {}
            for (const row of Object.keys(clientsByRow).map(Number)) {
                const clients = clientsByRow[row].sort((a, b) => Number(a.at[0]) - Number(b.at[0]))
                windowsByRow[row] = clients.map((client, column) => ({
                    id: client.address,
                    app_id: client.class || client.initialClass || "",
                    title: client.title || "",
                    is_focused: Number(client.focusHistoryID) === 0,
                    is_floating: client.floating === true,
                    layout: { pos_in_scrolling_layout: [column + 1, row + 1], canvas_row: row },
                }))
            }
            const activeName = group.monitor && group.monitor.activeWorkspace ? group.monitor.activeWorkspace.name : ""
            const rawWorkspace = workspaceState[group.name] || {}
            const ws = {
                id: group.name,
                idx: Number(rawWorkspace.address || group.name) || 0,
                name: group.name,
                output: group.monitor ? group.monitor.name : "",
                is_active: group.name === activeName,
                is_focused: group.name === activeName && !!(group.monitor && group.monitor.focused),
                active_window_id: null,
            }
            for (const row of Object.keys(windowsByRow).map(Number).sort((a, b) => a - b))
                result.push({ ws: ws, windows: windowsByRow[row] })
        }
        return result
    }

    function visibleWorkspaces(output) {
        const _ = version
        if (canvasSnapshot) return canvasWorkspaces(output)
        const result = []
        const workspaces = Hyprland.workspaces.values || []
        for (const workspace of workspaces) {
            const normalized = normalizedWorkspace(workspace)
            if (isHiddenWorkspace(normalized)) continue
            if (output && normalized.output !== output) continue
            const windows = normalizedWindows(workspace)
            if (windows.length === 0) {
                result.push({ ws: normalized, windows: [] })
                continue
            }
            const rows = {}
            for (const window of windows) {
                const row = window.layout.canvas_row || 0
                if (!rows[row]) rows[row] = []
                rows[row].push(window)
            }
            for (const row of Object.keys(rows).map(Number).sort((a, b) => a - b))
                result.push({ ws: normalized, windows: rows[row] })
        }
        result.sort((a, b) => {
            if (a.ws.output !== b.ws.output) return a.ws.output < b.ws.output ? -1 : 1
            return a.ws.idx - b.ws.idx
        })
        return result
    }

    function focusedWindow() {
        return Hyprland.activeToplevel
    }

    function focusedAppId() {
        const object = objectFor(focusedWindow())
        return object.class || object.initialClass || ""
    }

    function focusedWorkspaceName() {
        return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.name : ""
    }

    function activeWorkspaceName(output) {
        const workspaces = Hyprland.workspaces.values || []
        for (const workspace of workspaces)
            if (workspace.active && outputForWorkspace(workspace) === output) return workspace.name || ""
        return ""
    }

    function focusedTitle() {
        return focusedWindow() ? focusedWindow().title || "" : ""
    }

    function focusedWindowId() {
        return focusedWindow() ? focusedWindow().address || "" : ""
    }

    function focusedWindowGeom() {
        const window = focusedWindow()
        if (!window) return null
        const object = objectFor(window)
        const at = object.at
        const size = object.size
        if (!at || !size) return null
        const monitor = window.monitor
        return {
            x: Number(at[0]) - (monitor ? monitor.x : 0),
            y: Number(at[1]) - (monitor ? monitor.y : 0),
            w: Number(size[0]),
            h: Number(size[1]),
            floating: object.floating === true,
        }
    }

    function isFullscreenGeom(g, outputHeight) {
        return !!(g && outputHeight && g.y <= 1 && g.h >= outputHeight - 1)
    }

    function windowIsFullscreen(window) {
        const object = objectFor(window)
        return Number(object.fullscreen || 0) === 2
            || Number(object.fullscreenClient || 0) === 2
    }

    function focusedIsFullscreen(outputHeight) {
        const workspace = Hyprland.focusedWorkspace
        const windows = workspace && workspace.toplevels ? workspace.toplevels.values : []
        for (const window of windows)
            if (window.activated) return windowIsFullscreen(window)
        return false
    }

    function outputIsFullscreen(outputName, outputHeight) {
        const _ = version
        if (canvasSnapshot) {
            const monitors = {}
            for (const monitor of (canvasSnapshot.monitors || [])) monitors[monitor.id] = monitor
            for (const client of (canvasSnapshot.clients || [])) {
                const monitor = monitors[client.monitor]
                if (monitor && monitor.name === outputName && Number(client.focusHistoryID) === 0)
                    return Number(client.fullscreen || 0) === 2
                        || Number(client.fullscreenClient || 0) === 2
            }
            return false
        }
        const workspaces = Hyprland.workspaces.values || []
        for (const workspace of workspaces) {
            if (!workspace.active || outputForWorkspace(workspace) !== outputName) continue
            const windows = workspace.toplevels ? workspace.toplevels.values : []
            for (const window of windows)
                if (window.activated) return windowIsFullscreen(window)
        }
        return false
    }

    function focusedOutput() {
        return Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    }

    function minimapEntries(output) {
        const out = []
        for (const group of visibleWorkspaces(output)) {
            if (out.length > 0 && group.windows.length > 0) out.push({ kind: "gap" })
            if (group.windows.length === 0 && (group.ws.is_focused || group.ws.is_active)) {
                out.push({ kind: "dot" })
                continue
            }
            for (const window of group.windows) {
                out.push({
                    kind: "bar",
                    focused: window.is_focused,
                    wsActive: !group.ws.is_focused && window.id === group.ws.active_window_id,
                })
            }
        }
        return out
    }
}
