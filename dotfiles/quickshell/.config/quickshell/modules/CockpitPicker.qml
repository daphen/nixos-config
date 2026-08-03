import QtQuick
import "."

// Cockpit context switcher. Enter points every cockpit window at the context;
// typing a name that matches nothing + Enter creates it (the house
// type-to-add pattern, same as TodoListPicker); Ctrl+W closes its tabs.
Picker {
    id: root

    open: CockpitState.open
    onCloseRequested: CockpitState.open = false

    placeholder: "contexts…"
    enterLabel: "switch"
    altLabel: "Ctrl+Enter: open app · Ctrl+P: open plan · Ctrl+W: close context"
    // Say what Enter will do with what is actually typed, instead of teaching
    // all three behaviours up front in the placeholder. Mirrors the predicates
    // in onEmptyEnter below — keep the two in step.
    emptyText: {
        const t = root.query.trim()
        if (t.length === 0) return "type a name + enter to create a context"
        if (/^[a-zA-Z]{2,}-\d+$/.test(t)) return "enter → plan " + t.toUpperCase()
        if (/^\d+$/.test(t)) return "enter → plan EVERY-" + t
        const name = t.replace(/[^a-zA-Z0-9-]/g, "")
        return name.length ? "enter → create context “" + name + "”" : "type a name + enter to create a context"
    }
    trailingField: "trailing"
    trailingColorField: "trailingColor"
    ctrlEnterAlt: true

    // The state glyph owns the row's left slot, so "current" reads as a badge —
    // highlightField's dot would draw on top of the glyph. Current is pinned
    // on top; the rest follow in MRU order so the last-used context sits
    // directly beneath it (and holds the initial selection: Enter = bounce back).
    items: {
        const cur = [], rest = []
        for (const c of CockpitState.contexts)
            (c.name === CockpitState.active ? cur : rest).push(c)
        const order = CockpitState.recent
        rest.sort((a, b) => {
            const ia = order.indexOf(a.name), ib = order.indexOf(b.name)
            return (ia < 0 ? 1e9 : ia) - (ib < 0 ? 1e9 : ib)
        })
        return cur.concat(rest).map(c => ({
            name: c.name,
            label: c.name,
            trailing: c.plan
                ? c.plan + (c.steps ? "  ·  " + c.steps : "")
                : "",
            // Lifecycle at a glance: authoring = yellow, ready = sky,
            // running = green, done = muted.
            trailingColor: c.plan === "implementing" ? Theme.green
                         : c.plan === "draft" ? Theme.yellow
                         : c.plan === "planned" ? Theme.sky
                         : Theme.fg_muted,
            glyph: c.state === "working" ? "●"
                 : c.state === "awaiting-you" ? "◔"
                 : c.state === "pending" ? "◐" : "○",
            glyphColor: c.state === "working" ? Theme.green
                      : c.state === "awaiting-you" ? Theme.cursor
                      : c.state === "pending" ? Theme.fg
                      : Theme.fg_muted,
            badge: c.name === CockpitState.active ? "current" : "",
        }))
    }

    // Land the initial highlight on the last-used row (index 1), after the
    // base's own open-reset has run.
    onOpenChanged: {
        if (!open) return
        Qt.callLater(() => {
            if (query.length === 0 && filtered.length > 1
                && filtered[0].badge === "current")
                selectedIndex = 1
        })
    }
    glyphField: "glyph"
    glyphColorField: "glyphColor"
    badgeField: "badge"

    onEnter: item => CockpitState.switchTo(item.name)
    onAltAction: item => CockpitState.openApp(item.name)
    onCtrlP: item => CockpitState.openPlan(item.name)
    onEmptyEnter: text => {
        const t = text.trim()
        // A Linear ticket id (EVERY-1234 / every-1234, or a bare number in the
        // user's shorthand) → open it straight into /plan-ticket in the rail,
        // rather than creating a cockpit context.
        if (/^[a-zA-Z]{2,}-\d+$/.test(t)) {
            CockpitState.planTicket(t.toUpperCase())
            CockpitState.open = false
            return
        }
        if (/^\d+$/.test(t)) {
            CockpitState.planTicket("EVERY-" + t)
            CockpitState.open = false
            return
        }
        const name = t.replace(/[^a-zA-Z0-9-]/g, "")
        if (name.length === 0) return
        CockpitState.add(name)
        CockpitState.open = false
    }
    onDelete: item => CockpitState.close(item.name)
}
