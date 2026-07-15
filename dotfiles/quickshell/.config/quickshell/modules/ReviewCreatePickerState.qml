pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false

    // cached PR nodes: the picker paints these instantly on open while a
    // background fetch refreshes statuses and picks up new items. The raw
    // gh response is tee'd to disk by the fetch, so cold starts warm-paint.
    property var requestedNodes: []
    property var reviewedNodes: []
    property var mineNodes: []
    readonly property bool hasCache: requestedNodes.length > 0 || reviewedNodes.length > 0 || mineNodes.length > 0

    function parse(text) {
        try {
            const d = (JSON.parse(text || "{}").data) || {}
            const req = (d.requested && d.requested.nodes) || []
            const rev = (d.reviewed && d.reviewed.nodes) || []
            const mine = (d.mine && d.mine.nodes) || []
            // a failed fetch must not clobber a good cache
            if (req.length || rev.length || mine.length) {
                requestedNodes = req; reviewedNodes = rev; mineNodes = mine
                return true
            }
        } catch (e) {}
        return false
    }

    FileView {
        path: Quickshell.env("HOME") + "/.cache/quickshell/review-prs.json"
        onLoaded: if (!root.hasCache) root.parse(text())
        onLoadFailed: {}
    }

    function toggle() { open = !open }
    function show()   { open = true }
    function hide()   { open = false }

    IpcHandler {
        target: "review-create"
        function toggle() { root.toggle() }
        function show()   { root.show() }
        function hide()   { root.hide() }
    }
}
