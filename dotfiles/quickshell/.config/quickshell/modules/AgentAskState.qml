pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

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
    signal focusConfirmRequested(var ask)

    function discover() {
        if (scanner.running) return
        _found = []
        scanner.running = true
    }

    function _key(index, session) { return String(index) + ":" + session }

    function _upsert(index, message) {
        const key = _key(index, message.session || "")
        const next = asks.filter(ask => ask.key !== key)
        const ask = Object.assign({}, message)
        ask.key = key
        ask.socketIndex = index
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
        _routeEscalations()
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
                socket.write(JSON.stringify({ type: "prompt", session: orchestrator.name || orchestrator.id, message: escalation.prompt }) + "\n")
            _pendingEscalations = []
            return
        }
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
        if (message.type === "extension_ui_request"
                && ["confirm", "select", "input", "editor"].includes(message.method)) {
            _upsert(index, message)
            return
        }
        if (message.type === "turn_end" || message.type === "agent_end") {
            _remove(index, message.session || "")
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
