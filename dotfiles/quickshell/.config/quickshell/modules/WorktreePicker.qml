import QtQuick
import Quickshell
import Quickshell.Io
import "."

Picker {
    id: root

    open: WorktreePickerState.open
    onCloseRequested: WorktreePickerState.open = false

    placeholder: "worktrees"
    enterLabel: "focus"
    altLabel: "Ctrl+W: close worktree   ·   Ctrl+P: plan"
    highlightField: "active"
    items: buildItems(NiriState.version, recencyFile.recency, NiriState.activeStack)

    onEnter: item => Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-jump-adjacent", "lovable-" + item.name])
    onAltAction: item => Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-close-worktree", item.name])
    // Ctrl+P: open the worktree's live plan view. Key derivation mirrors
    // plan-nvim's plan_key: a ticket number in the short name keys as
    // EVERY-<num>; ad-hoc worktrees key as their slug.
    onCtrlP: item => Quickshell.execDetached(["bash", "-c",
        'n="$1"; num=$(grep -oE "[0-9]{2,}" <<<"$n" | head -1); ' +
        'k="${num:+EVERY-$num}"; k="${k:-$n}"; ' +
        'f="$HOME/personal/notes/storage/plans/$k.md"; ' +
        'if [ -f "$f" ]; then exec python3 "$HOME/.claude/skills/plan-ticket/plan-view.py" "$k" --open; ' +
        'else notify-send --app-name plan "no plan" "$k has no plan artifact"; fi',
        "_", item.name])

    FileView {
        id: recencyFile
        path: Quickshell.env("HOME") + "/.local/state/wt-stacks/ws/recency"
        watchChanges: true
        onFileChanged: reload()

        property var recency: []
        onLoaded: {
            try { recency = JSON.parse(text() || "[]") } catch (e) { recency = [] }
        }
        onLoadFailed: recency = []
    }

    function buildItems(_version, recency, activeStack) {
        const _ = _version
        const existing = []
        const wsMap = NiriState.workspaces
        for (const id in wsMap) {
            const n = wsMap[id].name || ""
            if (!n.startsWith("lovable-")) continue
            if (n === "lovable" || n === "lovable-main") continue
            existing.push(n.substring("lovable-".length))
        }
        const present = {}
        for (const n of existing) present[n] = true

        const activeBare = (activeStack || "").replace(/^lovable-/, "")
        const seen = {}
        const ordered = []
        for (const r of (recency || [])) {
            const bare = String(r).replace(/^lovable-/, "")
            if (present[bare] && !seen[bare]) { ordered.push(bare); seen[bare] = true }
        }
        for (const n of existing) {
            if (!seen[n]) { ordered.push(n); seen[n] = true }
        }

        return ordered.map(n => ({ name: n, label: n, active: n === activeBare }))
    }
}
