import QtQuick
import QtQuick.Effects
import Quickshell
import "."

PanelWindow {
    id: root

    screen: Quickshell.screens.length ? Quickshell.screens[0] : null

    readonly property var allTabs: PaletteState.tabs || []
    readonly property var allQuickmarks: PaletteState.quickmarks || []
    readonly property var tabs: allTabs.slice(tabPage * 8, tabPage * 8 + 8)
    readonly property var quickmarks: allQuickmarks
    readonly property int tabPageCount: Math.max(1, Math.ceil(allTabs.length / 8))
    property int tabPage: 0; property int quickmarkCursor: -1; property int direction: 0
    property bool outerActive: false; property var originalTabId: null
    readonly property color selectedSurface: Theme.mode === "light" ? Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.09) : Theme.surface1
    readonly property int selectedQuickmarkIndex: quickmarkCursor >= 0 ? quickmarkCursor : ringIndex(quickmarks)
    readonly property var selectedEntry: outerActive ? itemAt(quickmarks, selectedQuickmarkIndex) : ringItem(tabs)

    visible: PaletteState.open
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: dial }

    Component.onCompleted: {
        width = screen.width; height = screen.height; aboveWindows = true; focusable = true
    }

    function ringIndex(items) { return items.length ? Math.round(direction * items.length / 8) % items.length : -1 }

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

    function page(step) {
        if (outerActive && quickmarks.length) {
            quickmarkCursor = (selectedQuickmarkIndex + step + quickmarks.length) % quickmarks.length
        } else if (!outerActive) {
            tabPage = (tabPage + step + tabPageCount) % tabPageCount
        }
    }

    function itemTitle(item, outer) {
        return item ? String(outer ? (item.name || item.title || item.url) : (item.title || item.url || "Untitled"))
                    : (outer ? "No quickmarks" : "No open tabs")
    }
    function itemSubtitle(item, outer) {
        return item ? String(item.url || (outer ? "Quickmark" : "Open tab"))
                    : (outer ? "Add quickmarks from the browser palette" : "Open a tab in Helium")
    }

    function previewTab() {
        const tab = ringItem(tabs)
        if (tab && tab.id !== PaletteState.currentTabId) PaletteState.activateTab(tab.id, tab.windowId)
    }

    function radial(action, value) {
        if (action === "open") {
            originalTabId = PaletteState.currentTabId
            outerActive = value >= 8
            direction = value % 8
            if (!outerActive) previewTab()
        } else if (action === "direction") {
            quickmarkCursor = -1
            direction = value
            if (!outerActive) previewTab()
        } else if (action === "outer") {
            outerActive = value === 1
            if (!outerActive) previewTab()
        } else if (action === "page") {
            page(value)
            if (!outerActive) previewTab()
        } else if (action === "delete" && !outerActive) {
            const tab = ringItem(tabs)
            if (tab) PaletteState.closeTab(tab.id)
        } else if (action === "activate" && outerActive && selectedEntry) {
            PaletteState.gotoUrl(selectedEntry.url, false)
            PaletteState.hide()
        } else if (action === "cancel") {
            const original = allTabs.find(tab => tab.id === originalTabId)
            if (original) PaletteState.activateTab(original.id, original.windowId)
            PaletteState.hide()
        } else if (action === "finish") {
            PaletteState.hide()
        }
    }

    Connections { target: PaletteState; function onRadialRequested(action, value) { root.radial(action, value) } }

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
            model: root.quickmarks.length

            Rectangle {
                required property int index
                readonly property var entry: root.quickmarks[index]
                readonly property real angle: index * Math.PI * 2 / root.quickmarks.length - Math.PI / 2
                readonly property bool selected: root.outerActive
                    && root.selectedQuickmarkIndex === index
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
                    text: String(parent.entry.name || parent.entry.title || "?").slice(0, 1).toUpperCase()
                    color: parent.selected ? Theme.bg : Theme.fg
                    font { family: Theme.fontFamily; pixelSize: 18; weight: 700 }
                }
            }
        }

        Repeater {
            model: root.tabs.length

            Rectangle {
                required property int index
                readonly property var entry: root.tabs[index]
                readonly property real angle: root.tabAngle(index, root.tabs.length)
                readonly property real radialDistance: root.cardRadius(angle, width, height, root.tabs.length)
                readonly property bool selected: !root.outerActive
                    && root.ringIndex(root.tabs) === index
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
                        source: previewFrame.parent.entry && previewFrame.parent.entry.previewPath
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
                        visible: !parent.parent.entry || !parent.parent.entry.previewPath
                        source: parent.parent.entry && parent.parent.entry.faviconPath
                            ? "file://" + parent.parent.entry.faviconPath : ""
                        sourceSize.width: 60
                        sourceSize.height: 60
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
                        text: root.outerActive ? "QUICKMARK" : "TAB"
                        color: root.outerActive ? Theme.bg : Theme.fg_secondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                        font.weight: 700
                        font.letterSpacing: 1
                    }
                }

                Text {
                    width: parent.width
                    text: root.outerActive
                        ? "QUICKMARKS · LB · " + root.quickmarks.length + " ITEMS"
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
                text: "← → SELECT   ·   PG↑ PG↓ STEP   ·   SPACE LB RING   ·   ESC CLOSE"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: 600
                font.letterSpacing: 0.5
            }
        }
    }
}
