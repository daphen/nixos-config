pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../QsLib" as Lib

Singleton {
    id: root

    property var asks: []
    property int gen: 0
    property bool inputOpen: false
    property var inputAsk: null
    property var paths: []
    property var _found: []
    property var _sockets: ({})
    property var _orchestrators: ({})
    property var _pendingEscalations: []
    property var _rosterSessions: ({})
    property var _liveActivities: ({})
    property int rosterGen: 0
    property var _pendingReports: []
    readonly property var workingRoots: _workingRoots(rosterGen)
    signal focusConfirmRequested(var ask)

    function discover() {
        if (scanner.running) return
        _found = []
        scanner.running = true
    }

    function _key(index, session) { return String(index) + ":" + session }

    function _scope(index) {
        const match = String(paths[index] || "").match(/agentd-([^/]+)\.sock$/)
        return match ? match[1] : "personal"
    }

    function _workingRoots(_) {
        const roots = ({})
        for (const index in _rosterSessions) {
            const sessions = _rosterSessions[index] || []
            const byName = ({})
            for (const session of sessions)
                byName[session.name || session.id || ""] = session
            for (const session of sessions) {
                if (session.status !== "streaming") continue
                let top = session
                const seen = ({})
                while (top.parent && byName[top.parent] && !seen[top.parent]) {
                    seen[top.parent] = true
                    top = byName[top.parent]
                }
                const name = top.name || top.id || session.name || session.id || "agent"
                const key = _key(index, name)
                if (!roots[key]) roots[key] = {
                    key: _scope(index) + ":" + name,
                    name: name,
                    scope: _scope(index),
                    workers: 0,
                    activities: []
                }
                roots[key].workers++
                roots[key].activities.push(_liveActivities[_key(index, session.name || session.id || "")]
                    || session.currentTool || "thinking")
            }
        }
        return Object.values(roots)
    }

    function _upsert(index, message) {
        const key = _key(index, message.session || "")
        const next = asks.filter(ask => ask.key !== key)
        const ask = Object.assign({}, message)
        // user-bash sentinel: the rail wraps agent-proposed shell commands in a
        // machine title + JSON payload. Render it as the "! <command>" grammar
        // the rail uses instead of leaking the raw sentinel to the island/inbox.
        if (ask.title === "__cockpit_user_bash__") {
            try {
                const cmd = String(JSON.parse(String(ask.message || "")).command || "")
                if (cmd) { ask.title = "run this command?"; ask.message = "! " + cmd }
            } catch (e) {}
        }
        ask.key = key
        ask.socketIndex = index
        // Scope from the owning socket path (agentd-<scope>.sock) — clients pick
        // per-scope identity (avatars) off it.
        var sp = String(paths[index] || "")
        var m = sp.match(/agentd-([^/]+)\.sock$/)
        ask.scope = m ? m[1] : "personal"
        next.push(ask)
        asks = next
        gen++
    }

    function _remove(index, session) {
        const key = _key(index, session)
        const next = asks.filter(ask => ask.key !== key)
        if (next.length === asks.length) return
        asks = next
        gen++
    }

    function _reconcileRoster(index, sessions) {
        let orchestrator = null
        for (const session of sessions || [])
            if (session.profile === "lovable-orchestrator") { orchestrator = session; break }
        _orchestrators[index] = orchestrator
        _rosterSessions[index] = sessions || []
        rosterGen++
        _routeEscalations()
        _routeReports()
        const waiting = ({})
        for (const session of sessions || [])
            if (session.ask) waiting[session.name || session.id || ""] = true
        const next = asks.filter(ask => ask.socketIndex !== index || waiting[ask.session])
        if (next.length === asks.length) return
        asks = next
        gen++
    }

    function _routeEscalations() {
        if (!_pendingEscalations.length) return
        for (const index in _orchestrators) {
            const orchestrator = _orchestrators[index]
            const socket = _sockets[index]
            if (!orchestrator || !socket || !socket.connected) continue
            for (const escalation of _pendingEscalations)
                // steer, not prompt: a prompt queues until the orchestrator's next
                // idle, and its turns run long — the blocked worker sat waiting
                // while the answer was minutes-queued. Steer injects at the next
                // tool boundary and falls back to a prompt when idle.
                socket.write(JSON.stringify({ type: "steer", session: orchestrator.name || orchestrator.id, message: escalation.prompt }) + "\n")
            _pendingEscalations = []
            return
        }
    }

    function _routeReports() {
        if (!_pendingReports.length) return
        const remaining = []
        for (const report of _pendingReports) {
            let delivered = false
            for (const index in _sockets) {
                const socket = _sockets[index]
                if (!socket || !socket.connected) continue
                const sessions = _rosterSessions[index] || []
                if (!sessions.some(s => (s.name || s.id) === report.driver)) continue
                socket.write(JSON.stringify({ type: "prompt", session: report.driver, message: report.prompt }) + "\n")
                delivered = true
                break
            }
            if (!delivered) remaining.push(report)
        }
        _pendingReports = remaining
    }

    function onLine(data, index) {
        let message
        try { message = JSON.parse(data) } catch (e) { return }
        if (!message) return
        if (message.type === "ask_escalation") {
            _pendingEscalations = _pendingEscalations.concat([message])
            _routeEscalations()
            return
        }
        // Cross-daemon turn report: a driven session settled on a daemon that
        // doesn't host its driver (a VM worker driven by the local
        // orchestrator). Route the nudge to the socket that owns the driver —
        // the ask-escalation pattern, pointed the other way.
        if (message.type === "turn_report") {
            _pendingReports = _pendingReports.concat([message])
            _routeReports()
            return
        }
        if (message.type === "extension_ui_request"
                && ["confirm", "select", "input", "editor"].includes(message.method)) {
            _upsert(index, message)
            return
        }
        if (message.type === "tool_execution_start") {
            const next = Object.assign({}, _liveActivities)
            next[_key(index, message.session || "")] = Lib.AgentActivity.classify(message.toolName, message.args)
            _liveActivities = next
            rosterGen++
            return
        }
        if (message.type === "tool_execution_end" || message.type === "turn_end" || message.type === "agent_end") {
            const next = Object.assign({}, _liveActivities)
            delete next[_key(index, message.session || "")]
            _liveActivities = next
            rosterGen++
            if (message.type !== "tool_execution_end") _remove(index, message.session || "")
            return
        }
        if (message.type === "roster") _reconcileRoster(index, message.sessions || [])
    }

    function focusConfirm() {
        const ask = asks.find(item => item.method === "confirm")
        if (!ask) return "none"
        focusConfirmRequested(ask)
        return "focused"
    }

    function openInput(ask) {
        inputAsk = ask
        inputOpen = true
    }

    function closeInput() {
        inputOpen = false
        inputAsk = null
    }

    function answer(ask, payload) {
        if (!ask) return false
        const socket = _sockets[ask.socketIndex]
        if (!socket || !socket.connected) return false
        socket.write(JSON.stringify({ type: "answer", session: ask.session, response: payload }) + "\n")
        if (inputAsk && inputAsk.key === ask.key) closeInput()
        _remove(ask.socketIndex, ask.session)
        return true
    }

    Process {
        id: scanner
        command: ["sh", "-c", "for s in \"${XDG_RUNTIME_DIR:-/tmp}\"/agentd-*.sock; do [ -S \"$s\" ] && printf '%s\\n' \"$s\"; done"]
        stdout: SplitParser { onRead: data => root._found.push(String(data).trim()) }
        onExited: root.paths = root._found.slice()
    }

    Component.onCompleted: discover()
    Timer { interval: 3000; repeat: true; running: true; onTriggered: root.discover() }

    IpcHandler {
        target: "agent-ask"
        function focus(): string { return root.focusConfirm() }
    }

    Instantiator {
        model: root.paths
        delegate: Item {
            readonly property int socketIndex: index
            readonly property string socketPath: modelData
            Loader {
                id: socketLoader
                active: true
                sourceComponent: Socket {
                    path: socketPath
                    connected: true
                    parser: SplitParser { onRead: data => root.onLine(data, socketIndex) }
                    onConnectionStateChanged: root._sockets[socketIndex] = socketLoader.item
                }
                onLoaded: {
                    root._sockets[socketIndex] = item
                    root._routeEscalations()
                }
            }
            Timer {
                interval: 2000
                repeat: true
                running: !(socketLoader.item && socketLoader.item.connected)
                onTriggered: { socketLoader.active = false; socketLoader.active = true }
            }
        }
    }
}
