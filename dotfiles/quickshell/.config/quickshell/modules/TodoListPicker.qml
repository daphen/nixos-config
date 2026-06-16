import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "."

// Permanent quick-todo list. Mirrors Picker's chrome, but with todo keys:
// Enter toggles the selected item (stays open); typing a new line + Enter
// adds it; Ctrl+E opens the list in nvim for sweeping edits; Esc closes.
PanelWindow {
    id: root

    readonly property bool open: TodoListPickerState.open
    property int selectedIndex: 0
    readonly property string query: search ? search.text : ""

    readonly property var filtered: {
        const q = query.trim().toLowerCase()
        const items = TodoListPickerState.items
        if (q.length === 0) return items
        const out = []
        for (let i = 0; i < items.length; i++)
            if (String(items[i].text).toLowerCase().indexOf(q) >= 0) out.push(items[i])
        return out
    }

    property bool active: false
    visible: active
    onOpenChanged: {
        if (open) { closeDelay.stop(); active = true }
        else closeDelay.restart()
    }
    Timer { id: closeDelay; interval: 300; onTriggered: root.active = false }
    onActiveChanged: {
        if (active && search) { search.text = ""; selectedIndex = 0; search.forceActiveFocus() }
    }
    onQueryChanged: selectedIndex = 0

    function close() { TodoListPickerState.open = false }

    function activate() {
        const q = query.trim()
        if (q.length > 0 && filtered.length === 0) {
            TodoListPickerState.addItem(q)
            search.text = ""
            return
        }
        if (filtered.length === 0) return
        const idx = Math.max(0, Math.min(selectedIndex, filtered.length - 1))
        TodoListPickerState.toggleItem(filtered[idx]) // stays open for batch check-off
    }

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-picker"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
        id: dim
        anchors.fill: parent
        color: "#000000"
        opacity: root.open ? 0.35 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        id: notch
        anchors {
            bottom: parent.bottom
            bottomMargin: root.open ? 80 : -(height + 40)
            horizontalCenter: parent.horizontalCenter
            Behavior on bottomMargin {
                NumberAnimation { duration: 280; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.32, 0.72, 0.0, 1.0, 1.0, 1.0] }
            }
        }
        width: 720
        height: 420
        color: Theme.notch
        radius: Theme.notchRadius
        border.color: Theme.hairline
        border.width: 1
        scale: root.open ? 1.0 : 0.96
        opacity: root.open ? 1.0 : 0.0
        Behavior on scale { NumberAnimation { duration: 190; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0] } }
        Behavior on opacity { NumberAnimation { duration: 190; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0] } }

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            TextField {
                id: search
                width: parent.width
                placeholderText: "filter…  ·  type a new todo + enter to add"
                color: Theme.fg
                placeholderTextColor: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.5)
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 2
                font.weight: Theme.fontWeight
                background: Rectangle { color: "transparent"; border.color: Theme.hairline; border.width: 1; radius: Theme.radiusSm }
                padding: 10
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.close(); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.activate(); event.accepted = true
                    } else if (event.key === Qt.Key_E && (event.modifiers & Qt.ControlModifier)) {
                        TodoListPickerState.openInNvim(); event.accepted = true
                    } else if (event.key === Qt.Key_W && (event.modifiers & Qt.ControlModifier)) {
                        if (root.filtered.length > 0)
                            TodoListPickerState.removeItem(root.filtered[Math.max(0, Math.min(root.selectedIndex, root.filtered.length - 1))])
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                        if (root.filtered.length > 0) root.selectedIndex = Math.min(root.selectedIndex + 1, root.filtered.length - 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                        if (root.filtered.length > 0) root.selectedIndex = Math.max(root.selectedIndex - 1, 0)
                        event.accepted = true
                    }
                }
            }

            ListView {
                id: list
                width: parent.width
                height: parent.height - search.height - footer.height - parent.spacing * 2
                clip: true
                model: root.filtered
                currentIndex: root.selectedIndex
                spacing: 2

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: list.width
                    height: 36
                    color: index === root.selectedIndex ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10) : "transparent"
                    radius: Theme.radiusSm

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: (modelData && modelData.done ? "[x]  " : "[ ]  ") + (modelData ? String(modelData.text) : "")
                        color: (modelData && modelData.done) ? Theme.fg_muted : Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.weight: Theme.fontWeight
                        renderType: Text.NativeRendering
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.selectedIndex = index; TodoListPickerState.toggleItem(modelData) }
                    }
                }

                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            }

            Text {
                id: footer
                width: parent.width
                text: "enter: toggle  ·  type + enter: add  ·  ctrl+w: delete  ·  ctrl+e: edit in nvim  ·  esc: close"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                renderType: Text.NativeRendering
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
