import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "."

PanelWindow {
    id: root

    screen: Quickshell.screens.length ? Quickshell.screens[0] : null

    readonly property string home: Quickshell.env("HOME")
    readonly property var allTabs: PaletteState.tabs || []
    readonly property var allQuickmarks: PaletteState.quickmarks || []
    readonly property var tabs: allTabs.slice(tabPage * 8, tabPage * 8 + 8)
    readonly property int tabPageCount: Math.max(1, Math.ceil(allTabs.length / 8))
    readonly property var apps: [
        { title: "Slack", subtitle: "Messages", glyph: "S", command: [home + "/.config/hypr/scripts/desktop-launch", "slqs-client"] },
        { title: "Discord", subtitle: "dsqrd", glyph: "D", command: [home + "/.config/hypr/scripts/desktop-launch", "dsqrd-client"] },
        { title: "Cockpit", subtitle: "Personal cockpit", glyph: "C", command: [home + "/.config/hypr/scripts/desktop-launch", "deck-cockpit"] },
        { title: "Helium", subtitle: "Personal browser", glyph: "H", command: [home + "/.config/hypr/scripts/desktop-launch", home + "/.config/hypr/scripts/chromium-launch"] },
        { title: "Spotify", subtitle: "Music", glyph: "♫", command: [home + "/.config/hypr/scripts/desktop-launch", "kitty", "--class", "spotify_player", home + "/.config/hypr/scripts/spotify-player-launch"] },
        { title: "Mail", subtitle: "mlqs", glyph: "M", command: [home + "/.config/hypr/scripts/desktop-launch", "mlqs-client"] },
        { title: "Passwords", subtitle: "1Password", glyph: "1", command: [home + "/.config/hypr/scripts/desktop-launch", "opqs-client"] },
        { title: "Terminal", subtitle: "Kitty", glyph: ">", command: [home + "/.config/hypr/scripts/desktop-launch", "kitty"] }
    ]
    readonly property var actions: [
        { title: "Launcher", subtitle: "Applications and actions", glyph: "⌕", command: ["qs", "ipc", "call", "--", "launcher", "toggle"] },
        { title: "Controls", subtitle: "Control center", glyph: "⚙", command: ["qs", "ipc", "call", "--", "controlCenter", "toggle"] },
        { title: "Clipboard", subtitle: "Clipboard history", glyph: "▣", command: ["qs", "ipc", "call", "--", "clipboard", "toggle"] },
        { title: "Network", subtitle: "Wi-Fi picker", glyph: "⌁", command: ["qs", "ipc", "call", "--", "network", "toggle"] },
        { title: "Bluetooth", subtitle: "Device picker", glyph: "ᛒ", command: ["qs", "ipc", "call", "--", "bluetooth", "toggle"] },
        { title: "Timers", subtitle: "Timer picker", glyph: "◷", command: ["qs", "ipc", "call", "--", "timers", "toggle"] },
        { title: "Emoji", subtitle: "Emoji picker", glyph: "☺", command: ["qs", "ipc", "call", "--", "emoji", "toggle"] },
        { title: "Wallpaper", subtitle: "Choose wallpaper", glyph: "◫", command: ["qs", "ipc", "call", "--", "wallpaper-picker", "toggle"] }
    ]
    property int tabPage: 0
    property real direction: -1
    property int selectedOuterIndex: -1
    property bool outerActive: false
    property bool appsMode: false
    property var originalTabId: null
    readonly property var innerItems: appsMode ? apps : tabs
    readonly property var outerItems: appsMode ? actions : allQuickmarks
    readonly property color selectedSurface: Theme.mode === "light" ? Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.09) : Theme.surface1
    readonly property var selectedEntry: outerActive ? itemAt(outerItems, selectedOuterIndex) : ringItem(innerItems)

    visible: PaletteState.open
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: dial }

    Component.onCompleted: {
        width = screen.width; height = screen.height; aboveWindows = true; focusable = true
    }

    function ringIndex(items) {
        if (direction < 0 || !items.length) return -1
        if (items === innerItems && items.length === 8) {
            const target = direction * Math.PI / 4 - Math.PI / 2
            let nearest = 0
            let nearestDistance = Infinity
            for (let index = 0; index < items.length; index++) {
                const delta = target - tabAngle(index, items.length)
                const distance = Math.abs(Math.atan2(Math.sin(delta), Math.cos(delta)))
                if (distance < nearestDistance) {
                    nearest = index
                    nearestDistance = distance
                }
            }
            return nearest
        }
        return Math.round(direction * items.length / 8) % items.length
    }

    function updateStick(data) {
        if (appsMode) return
        const parts = String(data).trim().split(/\s+/); if (parts.length !== 2 || parts[0] !== "direction") return
        const value = Number(parts[1]); if (Number.isFinite(value)) radial(parts[0], value)
    }

    function tabAngle(index, count) {
        if (count === 8) {
            const degrees = [-90, -36.3, 0, 36.3, 90, 143.7, 180, 216.3]
            return degrees[index] * Math.PI / 180
        }
        return index * Math.PI * 2 / count - Math.PI / 2
    }

    function cardRadius(angle, width, height, count) {
        const edge = Math.abs(Math.cos(angle)) * width / 2 + Math.abs(Math.sin(angle)) * height / 2
        return 132 + edge + (count === 8 ? 9 * Math.abs(Math.sin(angle * 2)) : 0)
    }

    function itemAt(items, index) { return index < 0 || index >= items.length ? null : items[index] }
    function ringItem(items) { return itemAt(items, ringIndex(items)) }

    function step(value) {
        if (outerActive && outerItems.length) {
            selectedOuterIndex = (selectedOuterIndex + value + outerItems.length) % outerItems.length
        } else if (!appsMode) {
            tabPage = (tabPage + value + tabPageCount) % tabPageCount
            previewTab()
        }
    }

    function itemTitle(item, outer) {
        if (item) return String(item.name || item.title || item.url || "Untitled")
        if (appsMode) return outer ? "No actions" : "No applications"
        return outer ? "No quickmarks" : "No open tabs"
    }
    function itemSubtitle(item, outer) {
        if (item) return String(item.subtitle || item.url || (outer ? "Quickmark" : "Open tab"))
        if (appsMode) return outer ? "No actions configured" : "No applications configured"
        return outer ? "Add quickmarks from the browser palette" : "Open a tab in Helium"
    }

    function previewTab() {
        const tab = ringItem(tabs)
        if (tab) PaletteState.activateTab(tab.id, tab.windowId)
    }

    function radial(action, value) {
        if (action === "open") {
            originalTabId = PaletteState.currentTabId
            appsMode = value >= 16
            outerActive = value % 16 >= 8
            direction = appsMode ? value % 8 : -1
            selectedOuterIndex = ringIndex(outerItems)
            if (!outerActive && !appsMode) previewTab()
        } else if (action === "direction") { if (!visible) return
            const previousIndex = ringIndex(innerItems); direction = value
            if (outerActive) selectedOuterIndex = ringIndex(outerItems)
            else if (!appsMode && ringIndex(innerItems) !== previousIndex) previewTab()
        } else if (action === "outer") {
            outerActive = value === 1
            if (outerActive) selectedOuterIndex = ringIndex(outerItems)
            else if (!appsMode) previewTab()
        } else if (action === "step") {
            step(value)
        } else if (action === "delete" && !appsMode && !outerActive) {
            const tab = ringItem(tabs)
            if (tab) PaletteState.closeTab(tab.id)
        } else if (action === "activate" && selectedEntry) {
            if (appsMode) Quickshell.execDetached(selectedEntry.command)
            else if (outerActive) PaletteState.gotoUrl(selectedEntry.url, false)
            PaletteState.hide()
        } else if (action === "cancel") {
            if (!appsMode) {
                const original = allTabs.find(tab => tab.id === originalTabId)
                if (original) PaletteState.activateTab(original.id, original.windowId)
            }
            PaletteState.hide()
        } else if (action === "finish") {
            PaletteState.hide()
        }
    }

    Connections {
        target: PaletteState
        function onRadialRequested(action, value) {
            if (action !== "direction" || root.appsMode) root.radial(action, value)
        }
    }

    Process {
        running: root.visible && !root.appsMode
        command: [root.home + "/.config/hypr/scripts/deck-radial-stick"]
        stdout: SplitParser { onRead: data => root.updateStick(data) }
        onExited: {
            if (root.visible && !root.appsMode) root.radial("direction", -1)
        }
    }

    Rectangle {
        anchors.fill: parent; color: Theme.mode === "light" ? "#F2F2F4" : "#08090B"
        opacity: Theme.mode === "light" ? 0.9 : 0.86
    }

    Item {
        id: dial
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -24
        width: Math.min(parent.width - 48, 760)
        height: Math.min(parent.height - 48, 760)

        Rectangle {
            anchors.centerIn: parent
            width: dial.width - 36
            height: width
            radius: width / 2
            color: "transparent"
            border.width: root.outerActive ? 2 : 1
            border.color: root.outerActive ? Theme.orange : Theme.hairlineSoft
            opacity: root.outerActive ? 0.72 : 0.3
        }

        Repeater {
            model: root.outerItems.length

            Rectangle {
                required property int index
                readonly property var entry: root.outerItems[index]
                readonly property real angle: index * Math.PI * 2 / root.outerItems.length - Math.PI / 2
                readonly property bool selected: root.outerActive
                    && root.selectedOuterIndex === index
                width: 64
                height: width
                radius: width / 2
                x: dial.width / 2 + Math.cos(angle) * (dial.width / 2 - 36) - width / 2
                y: dial.height / 2 + Math.sin(angle) * (dial.height / 2 - 36) - height / 2
                color: selected ? Theme.orange : Theme.surface0
                border.width: selected ? 2 : (Theme.mode === "light" ? 1 : 0)
                border.color: selected ? Theme.orange : Theme.hairline
                opacity: root.outerActive ? 1 : 0.3
                scale: selected ? 1.06 : 1
                Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                Image {
                    id: quickmarkIcon
                    anchors.centerIn: parent
                    width: 30; height: width
                    source: parent.entry.faviconPath ? "file://" + parent.entry.faviconPath : ""
                    sourceSize.width: 60; sourceSize.height: 60
                    visible: status === Image.Ready
                }
                Text {
                    anchors.centerIn: parent
                    visible: quickmarkIcon.status !== Image.Ready
                    text: String(parent.entry.glyph || parent.entry.name || parent.entry.title || "?").slice(0, 1).toUpperCase()
                    color: parent.selected ? Theme.bg : Theme.fg
                    font { family: Theme.fontFamily; pixelSize: 18; weight: 700 }
                }
            }
        }

        Repeater {
            model: root.innerItems.length

            Rectangle {
                required property int index
                readonly property var entry: root.innerItems[index]
                readonly property real angle: root.tabAngle(index, root.innerItems.length)
                readonly property real radialDistance: root.cardRadius(angle, width, height, root.innerItems.length)
                readonly property bool selected: !root.outerActive
                    && root.ringIndex(root.innerItems) === index
                width: 140
                height: 92
                radius: 15
                x: dial.width / 2 + Math.cos(angle) * radialDistance - width / 2
                y: dial.height / 2 + Math.sin(angle) * radialDistance - height / 2
                color: selected ? root.selectedSurface : (Theme.mode === "light" ? Theme.surface0 : Theme.bg)
                border.width: selected ? 2 : (Theme.mode === "light" ? 1 : 0)
                border.color: selected ? Theme.orange : Theme.hairline
                opacity: root.outerActive ? 0.3 : 1

                Row {
                    id: tabHeading
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    spacing: 7

                    Image {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 17; height: width
                        source: parent.parent.entry.faviconPath ? "file://" + parent.parent.entry.faviconPath : ""
                        visible: !root.appsMode && status === Image.Ready
                        sourceSize.width: 34; sourceSize.height: 34
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 25
                        text: root.itemTitle(parent.parent.entry, false)
                        color: parent.parent.selected ? Theme.orange : Theme.fg
                        font { family: Theme.fontFamily; pixelSize: 11; weight: 700; letterSpacing: 0.4 }
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    id: previewFrame
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: tabHeading.bottom
                    anchors.bottom: parent.bottom
                    anchors.margins: 6
                    anchors.topMargin: 7
                    radius: 11
                    color: Theme.mode === "light" ? Theme.surface2 : Theme.surface0

                    Rectangle {
                        id: previewMask
                        anchors.fill: parent
                        radius: parent.radius; color: "white"; visible: false; layer.enabled: true
                    }

                    Image {
                        anchors.fill: parent
                        source: !root.appsMode && previewFrame.parent.entry && previewFrame.parent.entry.previewPath
                            ? "file://" + previewFrame.parent.entry.previewPath : ""
                        sourceSize.width: 456
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        visible: source !== ""
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            maskEnabled: true
                            maskSource: previewMask
                        }
                    }

                    Image {
                        anchors.centerIn: parent
                        width: 30
                        height: width
                        visible: !root.appsMode && (!parent.parent.entry || !parent.parent.entry.previewPath)
                        source: parent.parent.entry && parent.parent.entry.faviconPath
                            ? "file://" + parent.parent.entry.faviconPath : ""
                        sourceSize.width: 60
                        sourceSize.height: 60
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: root.appsMode
                        text: String(parent.parent.entry.glyph || parent.parent.entry.title || "?").slice(0, 1)
                        color: parent.parent.selected ? Theme.orange : Theme.fg
                        font { family: Theme.fontFamily; pixelSize: 28; weight: 700 }
                    }
                }
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: 242
            height: width
            radius: width / 2
            color: Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.34)
        }

        Rectangle {
            id: hub
            anchors.centerIn: parent
            width: 224
            height: width
            radius: width / 2
            color: Theme.surface0
            border.width: Theme.mode === "light" ? 1 : 0
            border.color: Theme.hairline

            Rectangle {
                anchors.fill: parent
                anchors.margins: 9
                radius: width / 2
                color: Theme.mode === "light" ? Theme.surface1 : Theme.bg
                border.width: 1
                border.color: root.outerActive ? Theme.orange : Theme.hairlineSoft
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: -4
                width: 42
                height: 8
                radius: 4
                color: Theme.orange
            }

            Column {
                anchors.centerIn: parent
                width: parent.width - 42
                spacing: 8

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: hubIcon.visible ? 38 : modeLabel.implicitWidth + 20
                    height: 28
                    radius: 14
                    color: root.outerActive ? Theme.orange : Theme.surface2
                    border.width: root.outerActive ? 0 : 1
                    border.color: Theme.hairline

                    Image {
                        id: hubIcon
                        anchors.centerIn: parent
                        width: 18
                        height: width
                        source: root.selectedEntry && root.selectedEntry.faviconPath
                            ? "file://" + root.selectedEntry.faviconPath : ""
                        sourceSize.width: 36
                        sourceSize.height: 36
                        visible: status === Image.Ready
                    }

                    Text {
                        id: modeLabel
                        anchors.centerIn: parent
                        visible: !hubIcon.visible
                        text: root.appsMode
                            ? (root.outerActive ? "ACTION" : "APP")
                            : (root.outerActive ? "QUICKMARK" : "TAB")
                        color: root.outerActive ? Theme.bg : Theme.fg_secondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                        font.weight: 700
                        font.letterSpacing: 1
                    }
                }

                Text {
                    width: parent.width
                    text: root.appsMode
                        ? (root.outerActive ? "ACTIONS · LB · " + root.actions.length + " ITEMS"
                                            : "APPLICATIONS · " + root.apps.length + " ITEMS")
                        : root.outerActive
                            ? "QUICKMARKS · LB · " + root.allQuickmarks.length + " ITEMS"
                            : "OPEN TABS · " + (root.tabPage + 1) + "/" + root.tabPageCount
                    color: root.outerActive ? Theme.orange : Theme.fg_muted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.weight: 700
                    font.letterSpacing: 1.1
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    width: parent.width
                    text: root.itemTitle(root.selectedEntry, root.outerActive)
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: 19
                    font.weight: 650
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: root.itemSubtitle(root.selectedEntry, root.outerActive)
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideMiddle
                }
            }
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.bottom
            anchors.topMargin: 10
            width: footerText.implicitWidth + 28
            height: 28
            radius: 14
            color: Theme.surface0
            border.width: Theme.mode === "light" ? 1 : 0
            border.color: Theme.hairline

            Text {
                id: footerText
                anchors.centerIn: parent
                text: root.appsMode
                    ? "LEFT STICK SELECT   ·   LB ACTIONS   ·   RELEASE LT OPEN   ·   B CLOSE"
                    : "RIGHT STICK SELECT   ·   LEFT STICK STEP   ·   LB QUICKMARKS   ·   RELEASE LT OPEN"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: 600
                font.letterSpacing: 0.5
            }
        }
    }
}
