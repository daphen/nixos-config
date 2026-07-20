pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// State + socket for the command palette (palette-daemon's QML UI).
// The daemon owns the browser mirror (tabs/windows/quickmarks across
// both Helium profiles) and pushes full `state` messages over
// $XDG_RUNTIME_DIR/palette-ui.sock; commands go back as one-line JSON.
Singleton {
    id: root

    property bool open: false
    property bool daemonConnected: false

    property string profile: ""
    property var tabs: []
    property var chin: []
    property var quickmarks: []
    property var currentTabId: null
    // Bumped on every state push so bindings recompute.
    property int gen: 0

    // History search results (request/response, not state-push: history is
    // query-shaped). reqId correlates replies; stale ones are discarded.
    property var historyEntries: []
    property int historyGen: 0
    property int _histReq: 0

    function toggle() { open = !open }
    function show()   { open = true }
    function hide()   { open = false }

    function send(obj) {
        const s = sockLoader.item
        if (s && s.connected) s.write(JSON.stringify(obj) + "\n")
    }
    function activateTab(tabId, windowId) { send({ cmd: "activate-tab", tabId: tabId, windowId: windowId }) }
    function gotoUrl(url, newTab)         { send({ cmd: "goto", url: url, newTab: !!newTab }) }
    function activateWindow(profile, windowId) { send({ cmd: "activate-window", profile: profile, windowId: windowId }) }
    function quickmarkAdd(name, url)      { send({ cmd: "quickmark-add", name: name, url: url }) }
    function closeTab(tabId)              { send({ cmd: "close-tab", tabId: tabId }) }
    function refresh()                    { send({ cmd: "refresh" }) }
    function searchHistory(query) {
        _histReq++
        send({ cmd: "history-search", reqId: _histReq, query: query || "" })
    }

    function onLine(data) {
        let m
        try { m = JSON.parse(data) } catch (e) { return }
        if (!m) return
        if (m.type === "history") {
            if (m.reqId === root._histReq) {   // stale replies lose
                root.historyEntries = m.entries || []
                root.historyGen++
            }
            return
        }
        if (m.type !== "state") return
        root.profile = m.profile || ""
        root.tabs = m.tabs || []
        root.chin = m.chin || []
        root.quickmarks = m.quickmarks || []
        root.currentTabId = (m.currentTabId === undefined) ? null : m.currentTabId
        root.gen++
    }

    // The Socket lives in a Loader so every re-dial gets a BRAND-NEW object:
    // after enough socket-file churn (daemon crash-loop clobbering the path),
    // a Socket wedges in a state where flipping `connected` never dials again
    // — the 2026-07-20 palette outage. Recreating the object is the only
    // reliable recovery, so the watchdog below rebuilds it while offline.
    Loader {
        id: sockLoader
        active: true
        sourceComponent: Socket {
            path: Quickshell.env("XDG_RUNTIME_DIR") + "/palette-ui.sock"
            connected: true
            parser: SplitParser { onRead: data => root.onLine(data) }
            onConnectionStateChanged: root.daemonConnected = connected
        }
    }
    Timer {
        interval: 2000
        repeat: true
        running: !root.daemonConnected
        onTriggered: { sockLoader.active = false; sockLoader.active = true }
    }

    IpcHandler {
        target: "palette"
        function toggle() { root.toggle() }
        function show()   { root.show() }
        function hide()   { root.hide() }
    }
}
