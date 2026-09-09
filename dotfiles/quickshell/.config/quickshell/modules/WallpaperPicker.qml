import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "."
import "../QsLib" as Lib

Item {
    id: root

    property bool open: WallpaperPickerState.open
    property bool active: false
    property var items: []
    property string currentPath: ""
    property int selectedIndex: 0
    property string query: search.text
    readonly property var filtered: {
        const needle = query.trim().toLowerCase()
        return needle ? items.filter(item => item.label.toLowerCase().includes(needle)) : items
    }
    implicitHeight: 302
    visible: active

    function resetSelection() {
        let next = 0
        if (!query.trim()) {
            for (let i = 0; i < filtered.length; i++) {
                if (filtered[i].path === currentPath) { next = i; break }
            }
        }
        selectedIndex = next
        Qt.callLater(function() { strip.positionViewAtIndex(next, ListView.Center) })
    }

    function step(amount) {
        if (filtered.length)
            selectedIndex = Math.max(0, Math.min(filtered.length - 1, selectedIndex + amount))
    }

    function applySelected() {
        if (!filtered.length) return
        const item = filtered[Math.max(0, Math.min(filtered.length - 1, selectedIndex))]
        Quickshell.execDetached([Quickshell.env("HOME") + "/.config/themes/link-mode-wallpaper.sh", item.path])
        WallpaperPickerState.hide()
    }

    onOpenChanged: {
        if (open) { closeDelay.stop(); active = true }
        else closeDelay.restart()
    }
    onActiveChanged: {
        if (!active) return
        search.text = ""
        loadProc.running = true
        search.forceActiveFocus()
    }
    onQueryChanged: resetSelection()
    onSelectedIndexChanged: Qt.callLater(function() {
        strip.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })

    Timer { id: closeDelay; interval: 300; onTriggered: root.active = false }

    Process {
        id: loadProc
        command: ["bash", "-c", "mode=$(cat \"$HOME/.config/theme_mode\" 2>/dev/null || echo dark); current=$(readlink -f \"$HOME/.config/themes/wallpaper-$mode\" 2>/dev/null || true); printf '%s\\n' \"$current\"; find \"$HOME/Pictures/Wallpapers\" -maxdepth 1 -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.bmp' \\) -print | sort"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = (this.text || "").split("\n")
                root.currentPath = lines.shift() || ""
                const found = []
                for (const path of lines) {
                    if (path) found.push({ path: path, label: path.substring(path.lastIndexOf("/") + 1) })
                }
                root.items = found
                root.resetSelection()
            }
        }
    }

    Item {
        anchors.fill: parent
        opacity: root.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }

        Column {
            anchors.fill: parent

            Item {
                width: parent.width; height: 68
                Rectangle {
                    id: searchField
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    anchors.topMargin: 14; anchors.bottomMargin: 6
                    radius: 15
                    color: Theme.surface2
                    border.width: 1; border.color: Theme.hairline
                }
                Text {
                    anchors.left: searchField.left; anchors.leftMargin: 14
                    anchors.verticalCenter: searchField.verticalCenter
                    text: "\uf002"
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 15
                }
                Lib.KeyCap {
                    id: escCap
                    anchors.right: searchField.right; anchors.rightMargin: 12
                    anchors.verticalCenter: searchField.verticalCenter
                    text: "esc"
                }
                TextField {
                    id: search
                    anchors.left: searchField.left; anchors.leftMargin: 38
                    anchors.right: escCap.left; anchors.rightMargin: 12
                    anchors.verticalCenter: searchField.verticalCenter
                    placeholderText: "Choose wallpaper…"
                    color: Theme.fg
                    placeholderTextColor: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.5)
                    font.family: Theme.fontFamily; font.pixelSize: 18
                    background: null; padding: 8
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            WallpaperPickerState.hide(); event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.applySelected(); event.accepted = true
                        } else if (event.key === Qt.Key_Right || (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier))) {
                            root.step(1); event.accepted = true
                        } else if (event.key === Qt.Key_Left || (event.key === Qt.Key_H && (event.modifiers & Qt.ControlModifier))) {
                            root.step(-1); event.accepted = true
                        } else if (event.key === Qt.Key_Home) {
                            root.selectedIndex = 0; event.accepted = true
                        } else if (event.key === Qt.Key_End) {
                            root.selectedIndex = Math.max(0, root.filtered.length - 1); event.accepted = true
                        }
                    }
                }
            }

            ListView {
                id: strip
                width: parent.width; height: 182
                orientation: ListView.Horizontal
                clip: true
                spacing: 8
                leftMargin: 14; rightMargin: 14
                cacheBuffer: 480
                model: root.filtered
                currentIndex: root.selectedIndex

                WheelHandler {
                    target: null
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        const delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 2
                        strip.contentX -= delta
                        strip.returnToBounds()
                        event.accepted = true
                    }
                }

                delegate: Item {
                    id: tile
                    required property var modelData
                    required property int index
                    width: 226; height: strip.height

                    Rectangle {
                        anchors.fill: parent
                        anchors.topMargin: 8; anchors.bottomMargin: 8
                        radius: 13
                        color: tile.index === root.selectedIndex ? Theme.itemCursor
                             : tileHover.hovered ? Theme.itemHover : "transparent"
                        Image {
                            anchors.fill: parent
                            anchors.margins: 7
                            source: "file://" + tile.modelData.path
                            sourceSize.width: 424; sourceSize.height: 256
                            asynchronous: true
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                        }
                    }
                    HoverHandler {
                        id: tileHover
                        cursorShape: Qt.PointingHandCursor
                        onHoveredChanged: if (hovered) root.selectedIndex = tile.index
                    }
                    TapHandler { onTapped: root.selectedIndex = tile.index }
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.filtered.length === 0
                    text: root.items.length === 0 ? "no wallpapers found" : "no matching wallpapers"
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 13
                }
            }

            Item {
                width: parent.width; height: 52
                Rectangle { width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    anchors.left: parent.left; anchors.leftMargin: 22
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 7
                    Lib.KeyCap { text: "←" }
                    Lib.KeyCap { text: "→" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "move"
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.pixelSize: 12
                    }
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: 22
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 7
                    Lib.KeyCap { text: "↵" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "set wallpaper"
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.pixelSize: 12
                    }
                }
            }
        }
    }
}
