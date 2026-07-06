pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Plan progress for the focused lovable worktree, from the plan-ticket
// artifacts (<vault>/plans/<key>.progress.json). Feeds the bar's worktree
// pill; the nvim panel reads the same file, so the two always agree.
Singleton {
    id: root

    property bool available: false
    property string phase: ""
    property int done: 0
    property int total: 0

    readonly property string wsShort: {
        const _ = NiriState.version
        const name = NiriState.focusedWorkspaceName()
        if (!name.startsWith("lovable-")) return ""
        if (name === "lovable" || name === "lovable-deps") return ""
        return name.substring("lovable-".length)
    }

    // Same derivation as plan-nvim's plan_key: number in the name -> ticket
    // key, else the short name itself (ad-hoc slug plans).
    readonly property string planKey: {
        if (!wsShort) return ""
        const m = wsShort.match(/[0-9]{2,}/)
        return m ? "EVERY-" + m[0] : wsShort
    }

    readonly property string icon: phase === "reconciled" ? "󰄲"    // nf-md-checkbox_marked
                                 : phase === "implementing" ? "󰦖"  // nf-md-progress_clock
                                 : phase === "finalized" ? "󰄬"     // nf-md-check
                                 : "󰏫"                             // nf-md-pencil (draft)

    function _parse() {
        try {
            const p = JSON.parse(file.text())
            const flow = p.flow || []
            let d = 0
            for (let i = 0; i < flow.length; i++)
                if (flow[i].status === "done") d++
            done = d
            total = flow.length
            phase = p.phase || ""
            available = true
        } catch (e) {
            available = false
        }
    }

    FileView {
        id: file
        path: root.planKey
            ? Quickshell.env("HOME") + "/personal/notes/storage/plans/" + root.planKey + ".progress.json"
            : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root._parse()
        onLoadFailed: root.available = false
    }
}
