import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property bool open: false
    property bool opening: false
    property var rows: []
    property string output: ""
    property color accent: "#ff6b1a"
    property string message: ""
    property int selected: 0
    readonly property var filtered: rows.filter(row => (row.category + " " + row.label).toLowerCase().includes(search.text.toLowerCase()))
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("tune.py").toString().replace(/^file:\/\//, ""))

    function toggle() {
        if (open || opening) { close(); return }
        if (backend.running) return
        opening = true
        search.text = ""
        selected = 0
        request(["state"])
    }
    function close() { opening = false; open = false }
    function request(args) {
        if (backend.running) return
        backend.command = ["python3", helper].concat(args)
        backend.running = true
    }
    function adjust(direction, fine, reset) {
        if (!filtered.length || backend.running) return
        const key = filtered[selected].key
        request(reset ? ["reset", key] : ["step", key, String(direction), fine ? "fine" : "normal"])
    }

    IpcHandler {
        target: "canvas-tuning"
        function toggle(): void { root.toggle() }
    }
    Process {
        id: backend
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const state = JSON.parse(this.text)
                    if (state.error) root.message = "ERROR • " + state.error
                    else {
                        root.rows = state.rows
                        root.output = state.output
                        root.accent = state.accent
                        root.message = state.message
                    }
                } catch (error) { root.message = "ERROR • " + error }
                if (root.opening) {
                    root.opening = false
                    root.open = true
                    search.forceActiveFocus()
                }
            }
        }
    }
    PanelWindow {
        id: window
        visible: root.open
        screen: Quickshell.screens.find(screen => screen.name === root.output) || Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "canvas-tuning"
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        onVisibleChanged: if (visible) search.forceActiveFocus()

        Rectangle {
            id: panel
            width: Math.min(1120, window.width - 48)
            height: Math.min(window.height - 48, 166 + Math.max(1, root.filtered.length) * 60)
            anchors.horizontalCenter: parent.horizontalCenter
            y: 24
            radius: 26
            color: "#ed121517"
            border.color: "#354046"
            border.width: 1
            layer.enabled: root.open
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: "#cc000000"
                shadowBlur: 0.6
                shadowVerticalOffset: 8
                shadowHorizontalOffset: 0
            }
            Rectangle {
                id: searchBox
                x: 22; y: 22
                width: parent.width - 44; height: 72
                radius: 16
                color: "#e8202224"
                border.color: root.accent
                border.width: 2
                layer.enabled: root.open
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: root.accent
                    shadowBlur: 0.4
                    shadowOpacity: 0.4
                    shadowVerticalOffset: 0
                    shadowHorizontalOffset: 0
                }
                Text {
                    x: 22; anchors.verticalCenter: parent.verticalCenter
                    text: ">_"; color: root.accent
                    font { family: "monospace"; pixelSize: 23; bold: true }
                }
                TextInput {
                    id: search
                    x: 78; width: parent.width - 190
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#ededeb"; selectionColor: root.accent
                    font { family: "monospace"; pixelSize: 19; letterSpacing: 1 }
                    clip: true
                    onTextChanged: root.selected = 0
                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) root.close()
                        else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                            root.selected = Math.max(0, Math.min(root.filtered.length - 1, root.selected + (event.key === Qt.Key_Down ? 1 : -1)))
                            list.positionViewAtIndex(root.selected, ListView.Contain)
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right)
                            root.adjust(event.key === Qt.Key_Right ? 1 : -1, !!(event.modifiers & Qt.ShiftModifier), false)
                        else if (event.key === Qt.Key_Home) root.adjust(0, false, true)
                        else { event.accepted = false; return }
                        event.accepted = true
                    }
                    Text {
                        anchors.fill: parent
                        visible: !search.text.length
                        text: "TUNE THE LOOK  //  TYPE TO FILTER"
                        color: "#707477"; font: search.font
                        elide: Text.ElideRight
                    }
                }
                Text {
                    anchors { right: parent.right; rightMargin: 22; verticalCenter: parent.verticalCenter }
                    text: "[ ESC ]"; color: "#8d9294"
                    font { family: "monospace"; pixelSize: 15; letterSpacing: 1 }
                }
            }
            ListView {
                id: list
                x: 22; y: 108; width: parent.width - 44; height: parent.height - 166
                model: root.filtered
                spacing: 8; clip: true
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool chosen: index === root.selected
                    width: list.width; height: 52; radius: 13
                    color: chosen ? root.accent : "#ce242728"
                    border.color: chosen ? root.accent : "#333739"
                    Text {
                        x: 20; width: 88; anchors.verticalCenter: parent.verticalCenter
                        text: modelData.category; color: chosen ? "#71401f" : "#7b8082"
                        font { family: "monospace"; pixelSize: 12; letterSpacing: 1 }
                    }
                    Text {
                        x: 120; width: parent.width * 0.4 - 32; anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label; color: chosen ? "#121517" : "#e2e4e3"
                        elide: Text.ElideRight
                        font { family: "monospace"; pixelSize: 17; bold: chosen; letterSpacing: 0.8 }
                    }
                    Text {
                        anchors { right: track.left; rightMargin: 22; verticalCenter: parent.verticalCenter }
                        text: modelData.display; color: chosen ? "#121517" : root.accent
                        font { family: "monospace"; pixelSize: 15; bold: true }
                    }
                    Rectangle {
                        id: track
                        anchors { right: parent.right; rightMargin: 26; verticalCenter: parent.verticalCenter }
                        width: parent.width * 0.22; height: 4; radius: 2
                        color: chosen ? "#624329" : "#44484a"
                        Rectangle { width: parent.width * modelData.fraction; height: parent.height; radius: 2; color: chosen ? "#171b1d" : root.accent }
                        Rectangle { x: (parent.width - width) * modelData.fraction; y: -6; width: 3; height: 16; color: chosen ? "#171b1d" : root.accent }
                    }
                    TapHandler { onTapped: { root.selected = index; search.forceActiveFocus() } }
                }
                Text {
                    anchors.centerIn: parent; visible: !root.filtered.length
                    text: root.rows.length ? "NO MATCHING CONTROLS" : "SETTINGS UNAVAILABLE"
                    color: "#8d9294"; font.family: "monospace"
                }
            }
            Text {
                x: 24; y: parent.height - 43; width: parent.width - 48
                text: (root.filtered.length ? (root.selected + 1) + " OF " + root.filtered.length + "  //  " : "") + "↑↓ SELECT   ←→ ADJUST   SHIFT FINE   HOME RESET"
                color: "#c5c9ca"; font { family: "monospace"; pixelSize: 12; letterSpacing: 0.5 }
                elide: Text.ElideRight
            }
            Text {
                x: 24; y: parent.height - 24; width: parent.width - 48
                text: backend.running ? "APPLYING…" : root.message
                color: root.message.includes("ERROR") || root.message.includes("NOT SAVED") ? "#ff8d7b" : "#858c8e"
                font { family: "monospace"; pixelSize: 10; letterSpacing: 0.5 }
                elide: Text.ElideRight
            }
        }
    }
}
