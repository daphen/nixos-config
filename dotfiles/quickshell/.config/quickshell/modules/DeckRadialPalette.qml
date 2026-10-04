import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "."
import "../QsLib" as Lib

FloatingWindow {
    id: root

    screen: Quickshell.screens.length ? Quickshell.screens[0] : null

    readonly property string home: Quickshell.env("HOME")
    readonly property var allTabs: PaletteState.tabs || []
    readonly property var allQuickmarks: PaletteState.quickmarks || []
    readonly property var tabs: allTabs.slice(tabPage * 8, tabPage * 8 + 8)
    readonly property int tabPageCount: Math.max(1, Math.ceil(allTabs.length / 8))
    readonly property var apps: [
        { title: "Slack", subtitle: "Messages", brand: "file://" + home + "/.config/quickshell/assets/slack.svg", tint: true, command: [home + "/.config/hypr/scripts/desktop-launch", "slack"] },
        { title: "Discord", subtitle: "dsqrd", brand: "file://" + home + "/.config/quickshell/assets/discord.svg", tint: true, command: [home + "/.config/hypr/scripts/desktop-launch", home + "/.config/hypr/scripts/launch-discord-client"] },
        { title: "Cockpit", subtitle: "Personal cockpit", icon: "window-pointer", command: [home + "/.config/hypr/scripts/desktop-launch", "deck-cockpit"] },
        { title: "Helium", subtitle: "Personal browser", brand: Quickshell.iconPath("helium"), command: [home + "/.config/hypr/scripts/desktop-launch", home + "/.config/hypr/scripts/chromium-launch"] },
        { title: "Spotify", subtitle: "Music", brand: Quickshell.iconPath("spotify-client"), command: [home + "/.config/hypr/scripts/desktop-launch", "kitty", "--class", "spotify_player", home + "/.config/hypr/scripts/spotify-player-launch"] },
        { title: "Mail", subtitle: "mlqs", icon: "envelope", command: [home + "/.config/hypr/scripts/desktop-launch", "mlqs-client"] },
        { title: "Passwords", subtitle: "1Password", brand: Quickshell.iconPath("1password"), command: [home + "/.config/hypr/scripts/desktop-launch", "opqs-client"] },
        { title: "Terminal", subtitle: "Kitty", icon: "keyboard", command: [home + "/.config/hypr/scripts/desktop-launch", "kitty"] }
    ]
    readonly property var actions: [
        { title: "Launcher", subtitle: "Applications and actions", icon: "magnifier", command: ["qs", "ipc", "call", "--", "launcher", "toggle"] },
        { title: "Controls", subtitle: "Control center", icon: "sliders", command: ["qs", "ipc", "call", "--", "controlCenter", "toggle"] },
        { title: "Clipboard", subtitle: "Clipboard history", icon: "clipboard", command: ["qs", "ipc", "call", "--", "clipboard", "toggle"] },
        { title: "Network", subtitle: "Wi-Fi picker", icon: "wifi-2", command: ["qs", "ipc", "call", "--", "network", "toggle"] },
        { title: "Bluetooth", subtitle: "Device picker", icon: "link", command: ["qs", "ipc", "call", "--", "bluetooth", "toggle"] },
        { title: "Timers", subtitle: "Timer picker", icon: "timer-2", command: ["qs", "ipc", "call", "--", "timers", "toggle"] },
        { title: "Wallpaper", subtitle: "Choose wallpaper", icon: "image-mountain", command: ["qs", "ipc", "call", "--", "wallpaper-picker", "toggle"] },
        { title: "Theme", subtitle: "Toggle light and dark", icon: "dark-light", command: ["themectl", "toggle"] }
    ]
    component AppIcon: Item {
        id: appIcon
        required property var entry
        property color color: Theme.fg
        Image {
            anchors.fill: parent
            source: appIcon.entry && appIcon.entry.brand ? appIcon.entry.brand : ""
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            layer.enabled: !!appIcon.entry && !!appIcon.entry.tint
            layer.effect: MultiEffect { colorization: 1; colorizationColor: appIcon.color }
        }
        Lib.Icon {
            anchors.fill: parent
            name: appIcon.entry && appIcon.entry.icon ? appIcon.entry.icon : ""
            color: appIcon.color
        }
    }

    property int tabPage: 0
    property int windowPage: 0
    property real direction: -1
    property int pendingStickIndex: -1
    property int selectedMiddleIndex: -1
    property int selectedOuterIndex: -1
    property bool outerActive: false
    property bool appsMode: false
    property int appLayer: 0
    property var originalTabId: null
    HyprlandBackend { id: hyprlandBackend; visible: false }
    readonly property var allOpenApps: {
        const snapshot = hyprlandBackend.canvasSnapshot
        const clients = snapshot ? snapshot.clients : []
        return clients.filter(client => client.mapped !== false && client.hidden !== true
            && client.title !== "quickshell" && client.title !== "deck-radial-palette")
            .map(client => ({ title: client.class === "org.quickshell" ? client.title.split(" · ")[0]
                : client.class.startsWith("browser-") ? "Helium" : client.class,
                subtitle: client.title, address: client.address, icon: "window-pointer" }))
    }
    readonly property int windowPageCount: Math.max(1, Math.ceil(allOpenApps.length / 8))
    readonly property var openApps: allOpenApps.slice(windowPage * 8, windowPage * 8 + 8)
    readonly property var innerItems: appsMode ? openApps : tabs
    readonly property var middleItems: appsMode ? actions : []
    readonly property var outerItems: appsMode ? apps : allQuickmarks
    readonly property bool middleActive: appsMode && appLayer === 1
    readonly property bool outerRingActive: appsMode ? appLayer === 2 : outerActive
    readonly property color selectedSurface: Theme.mode === "light" ? Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.09) : Theme.surface1
    readonly property var selectedEntry: middleActive ? itemAt(middleItems, selectedMiddleIndex)
        : outerRingActive ? itemAt(outerItems, selectedOuterIndex) : ringItem(innerItems)

    visible: PaletteState.open
    title: "deck-radial-palette"
    implicitWidth: screen ? screen.width : 1280
    implicitHeight: screen ? screen.height : 800
    color: "transparent"
    mask: Region { item: dial }

    function ringIndex(items, value = direction) {
        if (value < 0 || !items.length) return -1
        if (items === innerItems && items.length === 8) {
            const target = value * Math.PI / 4 - Math.PI / 2
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
        return Math.round(value * items.length / 8) % items.length
    }

    function acceptedDirection(items, value) {
        if (value < 0) return value
        const current = ringIndex(items)
        const candidate = ringIndex(items, value)
        if (current < 0 || candidate < 0 || current === candidate) return value
        const target = value * Math.PI / 4 - Math.PI / 2
        const angle = index => items === innerItems
            ? tabAngle(index, items.length)
            : index * Math.PI * 2 / items.length - Math.PI / 2
        const distance = index => Math.abs(Math.atan2(Math.sin(target - angle(index)), Math.cos(target - angle(index))))
        return distance(candidate) + Math.PI / 10 < distance(current) ? value : direction
    }

    function updateStick(data) {
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
        if (middleActive && middleItems.length) {
            selectedMiddleIndex = (selectedMiddleIndex + value + middleItems.length) % middleItems.length
        } else if (outerRingActive && outerItems.length) {
            selectedOuterIndex = (selectedOuterIndex + value + outerItems.length) % outerItems.length
        } else if (appsMode) {
            windowPage = (windowPage + value + windowPageCount) % windowPageCount
        } else {
            tabPage = (tabPage + value + tabPageCount) % tabPageCount
            previewTab()
        }
    }

    function itemTitle(item, outer) {
        if (item) return String(item.name || item.title || item.url || "Untitled")
        if (appsMode) return ["No open apps", "No actions", "No applications"][appLayer]
        return outer ? "No quickmarks" : "No open tabs"
    }
    function itemSubtitle(item, outer) {
        if (item) return String(item.subtitle || item.url || (outer ? "Quickmark" : "Open tab"))
        if (appsMode) return ["No open windows", "No actions configured", "No applications configured"][appLayer]
        return outer ? "Add quickmarks from the browser palette" : "Open a tab in Helium"
    }

    function previewTab() {
        const tab = ringItem(tabs)
        if (tab) PaletteState.activateTab(tab.id, tab.windowId)
    }

    function radial(action, value) {
        if (action === "open") {
            pendingStickIndex = -1
            originalTabId = PaletteState.currentTabId
            appsMode = value >= 16
            outerActive = value % 16 >= 8
            appLayer = 0
            windowPage = 0
            direction = appsMode ? value % 8 : -1
            selectedMiddleIndex = ringIndex(middleItems)
            selectedOuterIndex = ringIndex(outerItems)
            if (!outerActive && !appsMode) previewTab()
        } else if (action === "direction") { if (!visible) return
            const items = middleActive ? middleItems : outerRingActive ? outerItems : innerItems
            const accepted = acceptedDirection(items, value)
            const current = ringIndex(items)
            const candidate = ringIndex(items, accepted)
            if (current >= 0 && candidate >= 0 && current !== candidate && pendingStickIndex !== candidate) {
                pendingStickIndex = candidate
                return
            }
            pendingStickIndex = -1
            const previousIndex = ringIndex(innerItems)
            direction = accepted
            if (middleActive) selectedMiddleIndex = ringIndex(middleItems)
            else if (outerRingActive) selectedOuterIndex = ringIndex(outerItems)
            else if (!appsMode && ringIndex(innerItems) !== previousIndex) previewTab()
        } else if (action === "cycle" && appsMode) {
            appLayer = (appLayer + 1) % 3
            pendingStickIndex = -1
            selectedMiddleIndex = ringIndex(middleItems)
            selectedOuterIndex = ringIndex(outerItems)
        } else if (action === "outer") {
            pendingStickIndex = -1
            outerActive = value === 1
            if (outerActive) selectedOuterIndex = ringIndex(outerItems)
            else if (!appsMode) previewTab()
        } else if (action === "step") {
            step(value)
        } else if (action === "delete" && !appsMode && !outerActive) {
            const tab = ringItem(tabs)
            if (tab) PaletteState.closeTab(tab.id)
        } else if (action === "activate") {
            if (selectedEntry) {
                if (appsMode && appLayer === 0) Quickshell.execDetached([home + "/.config/hypr/scripts/hypr-dispatch", "focuswindow", "address:" + selectedEntry.address])
                else if (appsMode) Quickshell.execDetached(selectedEntry.command)
                else if (outerActive) PaletteState.gotoUrl(selectedEntry.url, false)
            }
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
            root.radial(action, value)
        }
    }

    Process {
        running: root.visible
        command: [root.home + "/.config/hypr/scripts/deck-radial-stick", "left"]
        stdout: SplitParser { onRead: data => root.updateStick(data) }
    }

    Rectangle {
        id: backdrop
        anchors.fill: parent; color: Theme.mode === "light" ? "#F2F2F4" : "#08090B"
        opacity: 0
    }

    Item {
        id: dial
        opacity: 0
        states: State {
            name: "open"
            when: root.visible
            PropertyChanges { target: dial; opacity: 1 }
            PropertyChanges { target: backdrop; opacity: Theme.mode === "light" ? 0.48 : 0.38 }
        }
        transitions: Transition {
            to: "open"
            ParallelAnimation {
                NumberAnimation { target: dial; property: "opacity"; duration: 120; easing.type: Easing.OutCubic }
                SequentialAnimation {
                    PauseAnimation { duration: 220 }
                    NumberAnimation { target: backdrop; property: "opacity"; duration: 320; easing.type: Easing.OutCubic }
                }
            }
        }
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
            border.width: root.outerRingActive ? 2 : 1
            border.color: root.outerRingActive ? Theme.orange : Theme.hairlineSoft
            opacity: root.outerRingActive ? 0.72 : 0.3
        }

        Repeater {
            model: root.middleItems.length

            Rectangle {
                required property int index
                readonly property var entry: root.middleItems[index]
                readonly property real angle: index * Math.PI * 2 / root.middleItems.length - Math.PI / 2
                readonly property bool selected: root.middleActive && root.selectedMiddleIndex === index
                width: 48
                height: width
                radius: width / 2
                x: dial.width / 2 + Math.cos(angle) * (dial.width / 2 - 104) - width / 2
                y: dial.height / 2 + Math.sin(angle) * (dial.height / 2 - 104) - height / 2
                color: selected ? Theme.orange : Theme.surface0
                border.width: selected ? 2 : (Theme.mode === "light" ? 1 : 0)
                border.color: selected ? Theme.orange : Theme.hairline
                opacity: root.middleActive ? 1 : 0.3
                Lib.Icon {
                    anchors.centerIn: parent
                    width: 24; height: width
                    name: parent.entry.icon || ""
                    color: parent.selected ? Theme.bg : Theme.fg
                }
            }
        }

        Repeater {
            model: root.outerItems.length

            Rectangle {
                required property int index
                readonly property var entry: root.outerItems[index]
                readonly property real angle: index * Math.PI * 2 / root.outerItems.length - Math.PI / 2
                readonly property bool selected: root.outerRingActive
                    && root.selectedOuterIndex === index
                width: 64
                height: width
                radius: width / 2
                x: dial.width / 2 + Math.cos(angle) * (dial.width / 2 - 36) - width / 2
                y: dial.height / 2 + Math.sin(angle) * (dial.height / 2 - 36) - height / 2
                color: selected ? Theme.orange : Theme.surface0
                border.width: selected ? 2 : (Theme.mode === "light" ? 1 : 0)
                border.color: selected ? Theme.orange : Theme.hairline
                opacity: root.outerRingActive ? 1 : 0.3
                scale: selected ? 1.06 : 1
                Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                Image {
                    id: quickmarkIcon
                    anchors.centerIn: parent
                    width: 30; height: width
                    source: !root.appsMode && parent.entry.faviconPath ? "file://" + parent.entry.faviconPath : ""
                    sourceSize.width: 60; sourceSize.height: 60
                    visible: status === Image.Ready
                }
                AppIcon {
                    anchors.centerIn: parent
                    width: 28; height: width
                    visible: root.appsMode
                    entry: parent.entry
                    color: parent.selected ? Theme.bg : Theme.fg
                }
                Text {
                    anchors.centerIn: parent
                    visible: !root.appsMode && quickmarkIcon.status !== Image.Ready
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
                readonly property bool selected: !root.outerRingActive && !root.middleActive
                    && root.ringIndex(root.innerItems) === index
                width: 140
                height: 92
                radius: 15
                x: dial.width / 2 + Math.cos(angle) * radialDistance - width / 2
                y: dial.height / 2 + Math.sin(angle) * radialDistance - height / 2
                color: selected ? root.selectedSurface : (Theme.mode === "light" ? Theme.surface0 : Theme.bg)
                border.width: selected ? 2 : (Theme.mode === "light" ? 1 : 0)
                border.color: selected ? Theme.orange : Theme.hairline
                opacity: root.outerRingActive || root.middleActive ? 0.3 : 1

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

                    AppIcon {
                        anchors.centerIn: parent
                        width: 32; height: width
                        visible: root.appsMode
                        entry: parent.parent.entry
                        color: parent.parent.selected ? Theme.orange : Theme.fg
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
                border.color: root.outerRingActive || root.middleActive ? Theme.orange : Theme.hairlineSoft
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
                    width: hubIcon.visible || hubAppIcon.visible ? 38 : modeLabel.implicitWidth + 20
                    height: 28
                    radius: 14
                    color: root.outerRingActive || root.middleActive ? Theme.orange : Theme.surface2
                    border.width: root.outerRingActive || root.middleActive ? 0 : 1
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

                    AppIcon {
                        id: hubAppIcon
                        anchors.centerIn: parent
                        width: 18; height: width
                        visible: root.appsMode && root.appLayer !== 1 && !!root.selectedEntry
                        entry: root.selectedEntry
                    }

                    Text {
                        id: modeLabel
                        anchors.centerIn: parent
                        visible: !hubIcon.visible && !hubAppIcon.visible
                        text: root.appsMode
                            ? ["OPEN", "ACTION", "LAUNCH"][root.appLayer]
                            : (root.outerActive ? "QUICKMARK" : "TAB")
                        color: root.outerRingActive || root.middleActive ? Theme.bg : Theme.fg_secondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                        font.weight: 700
                        font.letterSpacing: 1
                    }
                }

                Text {
                    width: parent.width
                    text: root.appsMode
                        ? ["OPEN APPS · " + root.allOpenApps.length + " WINDOWS",
                           "ACTIONS · " + root.actions.length + " ITEMS",
                           "LAUNCHER · " + root.apps.length + " APPS"][root.appLayer]
                        : root.outerActive
                            ? "QUICKMARKS · LB · " + root.allQuickmarks.length + " ITEMS"
                            : "OPEN TABS · " + (root.tabPage + 1) + "/" + root.tabPageCount
                    color: root.outerRingActive || root.middleActive ? Theme.orange : Theme.fg_muted
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
                    visible: root.appsMode || !root.outerActive || !root.selectedEntry
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
                    ? "LEFT STICK SELECT   ·   LB NEXT RING   ·   RELEASE LT OPEN   ·   B CLOSE"
                    : "RIGHT STICK TABS   ·   LEFT STICK QUICKMARKS   ·   B CLOSE"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: 600
                font.letterSpacing: 0.5
            }
        }
    }
}
