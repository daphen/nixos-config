import QtQuick
import "."

// Cockpit context switcher. Enter points every cockpit window at the context;
// typing a name that matches nothing + Enter creates it (the house
// type-to-add pattern, same as TodoListPicker); Ctrl+W closes its tabs.
Picker {
    id: root

    open: CockpitState.open
    onCloseRequested: CockpitState.open = false

    placeholder: "contexts…  ·  type a new name + enter to create"
    enterLabel: "switch"
    altLabel: "Ctrl+W: close context"
    emptyText: "no contexts — type a name + enter to create one"

    // The state glyph owns the row's left slot, so "active" reads as a badge —
    // highlightField's dot would draw on top of the glyph.
    items: CockpitState.contexts.map(c => ({
        name: c.name,
        label: c.name,
        glyph: c.state === "working" ? "●" : c.state === "awaiting-you" ? "◔" : "○",
        glyphColor: c.state === "working" ? Theme.green
                  : c.state === "awaiting-you" ? Theme.cursor
                  : Theme.fg_muted,
        badge: c.name === CockpitState.active ? "active" : "",
    }))
    glyphField: "glyph"
    glyphColorField: "glyphColor"
    badgeField: "badge"

    onEnter: item => CockpitState.switchTo(item.name)
    onEmptyEnter: text => {
        const name = text.replace(/[^a-zA-Z0-9-]/g, "")
        if (name.length === 0) return
        CockpitState.add(name)
        CockpitState.open = false
    }
    onDelete: item => CockpitState.close(item.name)
}
