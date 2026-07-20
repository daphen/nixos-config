import QtQuick
import "."

// Permanent quick-todo list on the house Picker. Enter toggles the selected
// item and stays open (clear a pile in one visit); typing something that
// matches nothing + Enter adds it; Ctrl+W deletes; Ctrl+E opens the list in
// nvim for sweeping edits.
Picker {
    open: TodoListPickerState.open
    onCloseRequested: TodoListPickerState.open = false

    placeholder: "filter…  ·  type a new todo + enter to add"
    enterKeepsOpen: true
    enterLabel: "toggle"
    altKey: Qt.Key_E
    altLabel: "Ctrl+W: delete  ·  Ctrl+E: edit in nvim"
    emptyText: "nothing here — type a todo + enter to add it"

    items: TodoListPickerState.items.map(t => ({
        label: t.text, done: t.done, line: t.line,
        glyph: t.done ? "✓" : "○",
        glyphColor: t.done ? Theme.green : Theme.fg_muted,
    }))
    glyphField: "glyph"
    glyphColorField: "glyphColor"

    onEnter: item => TodoListPickerState.toggleItem(item)
    onEmptyEnter: text => TodoListPickerState.addItem(text)
    onDelete: item => TodoListPickerState.removeItem(item)
    onAltAction: item => {
        TodoListPickerState.openInNvim()
        TodoListPickerState.open = false
    }
}
