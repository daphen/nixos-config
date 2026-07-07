import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "."

PanelWindow {
    id: root

    property bool open: false
    signal closeRequested()
    property string placeholder: "Search…"
    property var items: []
    property string subtitleField: ""
    property string highlightField: ""
    // Optional per-item field holding an image source; renders a theme-tinted
    // monochrome icon at the right of the row (e.g. the notification center's
    // app logos). Tinted to fg_muted so it follows light/dark automatically.
    property string iconField: ""
    property var onEnter: function(item) {}
    property var onEnterText: function(text) {}
    property bool freeText: false
    property var onAltAction: null
    property string altLabel: ""
    property int altKey: Qt.Key_W
    // Set by pickers whose items arrive asynchronously: shows a loading
    // indicator, and the list fades in once loading clears.
    property bool loading: false
    // Optional per-item colored status glyph (a Nerd Font char) at the row's
    // left; its color comes from glyphColorField (a color value on the item).
    property string glyphField: ""
    property string glyphColorField: ""
    // When true, Ctrl+Enter fires the alt action instead of the primary one.
    property bool ctrlEnterAlt: false
    // Opt-in tab bar: labels shown under the search field, Tab/Shift+Tab cycles.
    // Pickers bind their items on `tab` to swap datasets.
    property var tabs: []
    property int tab: 0
    onTabChanged: selectedIndex = firstSelectable()
    // Opt-in Ctrl+Y: called with the focused item (yank/copy semantics).
    property var onYank: null
    // Opt-in Ctrl+P: called with the focused item, then the picker closes.
    property var onCtrlP: null

    property string query: search ? search.text : ""
    property int selectedIndex: 0

    // Small keycap chip (esc, arrows, enter) — the reference-palette detail.
    component KeyCap: Rectangle {
        property alias text: capText.text
        width: Math.max(capText.implicitWidth + 14, 24)
        height: 24
        radius: 7
        // Reference: light-mode keycaps are white and raised; dark stays tinted.
        color: Theme.mode === "light" ? Theme.bg : Theme.surface2
        border.color: Theme.hairline
        border.width: 1
        Text {
            id: capText
            anchors.centerIn: parent
            color: Theme.fg_muted
            font.family: notch.sans
            font.pixelSize: 12
            font.weight: 500
            renderType: Text.NativeRendering
        }
    }

    // Natural height of the list (rows + spacing + margins) so the panel
    // can hug its content instead of showing a fixed-height void.
    readonly property int listContentHeight: {
        let h = 18
        for (let i = 0; i < filtered.length; i++) {
            const it = filtered[i]
            if (it && it.divider) h += 36
            else h += (subtitleField.length > 0 && it && String(it[subtitleField] || "").length > 0) ? 60 : 44
            if (i > 0) h += 2
        }
        return h
    }

    // Rows under a divider until the next one — shown as the section count.
    function sectionCount(i) {
        let c = 0
        for (let j = i + 1; j < filtered.length; j++) {
            if (filtered[j] && filtered[j].divider) break
            c++
        }
        return c
    }

    property bool active: false
    visible: active

    onOpenChanged: {
        if (open) { closeDelay.stop(); active = true }
        else closeDelay.restart()
    }
    Timer { id: closeDelay; interval: 300; onTriggered: root.active = false }

    onActiveChanged: {
        if (active && search) {
            search.text = ""
            selectedIndex = firstSelectable()
            search.forceActiveFocus()
        }
    }
    onQueryChanged: selectedIndex = firstSelectable()

    // First non-divider row — so selection never starts on a section header.
    function firstSelectable() {
        for (let i = 0; i < filtered.length; i++)
            if (!filtered[i] || !filtered[i].divider) return i
        return 0
    }

    readonly property var filtered: {
        const q = query.trim().toLowerCase()
        if (q.length === 0) return items
        // While searching, drop section dividers — they're only meaningful
        // in the unfiltered, grouped view.
        const out = []
        for (let i = 0; i < items.length; i++) {
            const it = items[i]
            if (it.divider) continue
            const label = String(it.label || "").toLowerCase()
            const sub = subtitleField && it[subtitleField] ? String(it[subtitleField]).toLowerCase() : ""
            if (label.indexOf(q) >= 0 || (sub && sub.indexOf(q) >= 0)) out.push(it)
        }
        return out
    }

    // Move selection by `dir`, skipping non-selectable divider rows.
    function step(dir) {
        const n = filtered.length
        if (n === 0) return
        let i = selectedIndex + dir
        while (i >= 0 && i < n && filtered[i] && filtered[i].divider) i += dir
        if (i >= 0 && i < n) selectedIndex = i
    }

    function activate() {
        if (freeText) {
            const text = query.trim()
            if (text.length === 0) return
            onEnterText(text)
            closeRequested()
            return
        }
        if (filtered.length === 0) return
        const idx = Math.max(0, Math.min(selectedIndex, filtered.length - 1))
        const item = filtered[idx]
        if (item && item.divider) return
        onEnter(item)
        closeRequested()
    }

    function altActivate() {
        if (!onAltAction || filtered.length === 0) return
        const idx = Math.max(0, Math.min(selectedIndex, filtered.length - 1))
        onAltAction(filtered[idx])
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
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
        Keys.onEscapePressed: root.closeRequested()
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeRequested()
        }
    }

    Rectangle {
        id: notch
        anchors {
            bottom: parent.bottom
            bottomMargin: root.open ? 80 : -(height + 40)
            horizontalCenter: parent.horizontalCenter

            Behavior on bottomMargin {
                NumberAnimation {
                    duration: 280
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: [0.32, 0.72, 0.0, 1.0, 1.0, 1.0]
                }
            }
        }
        width: 760
        // Hug the content like the reference — footer sits right under the
        // last row; 480 caps long lists (the ListView scrolls past that).
        height: Math.min(480, inputWrap.height + tabsRow.height + root.listContentHeight + footer.height)
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        color: Theme.bg
        // Radii from the reference palette: panel 24, field 15, cards 13.
        radius: 24
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)
        border.width: 1
        clip: true

        scale: root.open ? 1.0 : 0.96
        opacity: root.open ? 1.0 : 0.0
        Behavior on scale {
            NumberAnimation {
                duration: 190
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0]
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: 190
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0]
            }
        }

        readonly property string sans: "Geist"

        Column {
            anchors.fill: parent

            Item {
                id: inputWrap
                width: parent.width
                height: 68

                Rectangle {
                    id: searchField
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    anchors.topMargin: 14
                    anchors.bottomMargin: 6
                    radius: 15
                    color: Theme.surface2
                }

                Text {
                    id: searchIcon
                    anchors.left: searchField.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: searchField.verticalCenter
                    text: "\uf002"
                    color: Theme.fg_muted
                    opacity: 0.85
                    font.family: Theme.fontFamily
                    font.pixelSize: 15
                    renderType: Text.NativeRendering
                }

                KeyCap {
                    id: escCap
                    anchors.right: searchField.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: searchField.verticalCenter
                    text: "esc"
                    TapHandler { onTapped: root.closeRequested() }
                }

            TextField {
                id: search
                anchors.left: searchIcon.right
                anchors.leftMargin: 10
                anchors.right: escCap.left
                anchors.rightMargin: 12
                anchors.verticalCenter: searchField.verticalCenter
                placeholderText: root.placeholder
                color: Theme.fg
                placeholderTextColor: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.5)
                font.family: notch.sans
                font.pixelSize: 18
                background: null
                padding: 8
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.closeRequested()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (root.ctrlEnterAlt && (event.modifiers & Qt.ControlModifier)) root.altActivate()
                        else root.activate()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down
                            || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                        root.step(1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up
                            || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                        root.step(-1)
                        event.accepted = true
                    } else if (event.key === root.altKey && (event.modifiers & Qt.ControlModifier)) {
                        root.altActivate()
                        event.accepted = true
                    } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier) && root.onCtrlP) {
                        const idx = Math.max(0, Math.min(root.selectedIndex, root.filtered.length - 1))
                        if (root.filtered.length > 0 && !root.filtered[idx].divider) {
                            root.onCtrlP(root.filtered[idx])
                            root.closeRequested()
                        }
                        event.accepted = true
                    } else if (event.key === Qt.Key_Y && (event.modifiers & Qt.ControlModifier) && root.onYank) {
                        const idx = Math.max(0, Math.min(root.selectedIndex, root.filtered.length - 1))
                        if (root.filtered.length > 0 && !root.filtered[idx].divider) root.onYank(root.filtered[idx])
                        event.accepted = true
                    } else if (root.tabs.length > 1
                            && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab
                                || ((event.key === Qt.Key_H || event.key === Qt.Key_L) && (event.modifiers & Qt.ControlModifier)))) {
                        const dir = (event.key === Qt.Key_Backtab
                                     || (event.key === Qt.Key_H && (event.modifiers & Qt.ControlModifier))) ? -1 : 1
                        root.tab = (root.tab + dir + root.tabs.length) % root.tabs.length
                        event.accepted = true
                    }
                }
            }
            }

            Item {
                id: tabsRow
                visible: root.tabs.length > 1
                width: parent.width
                height: visible ? 41 : 0

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Repeater {
                        model: root.tabs
                        Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool isActive: index === root.tab
                            width: tabLabel.implicitWidth + 20
                            height: tabLabel.implicitHeight + 12
                            radius: 6
                            color: isActive ? Theme.selection
                                 : tabHover.hovered ? Theme.surface : "transparent"
                            Text {
                                id: tabLabel
                                anchors.centerIn: parent
                                text: String(parent.modelData)
                                color: parent.isActive ? Theme.fg : Theme.fg_muted
                                font.family: notch.sans
                                font.pixelSize: 13
                                font.weight: 500
                                renderType: Text.NativeRendering
                            }
                            HoverHandler { id: tabHover }
                            TapHandler { onTapped: root.tab = parent.index }
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.hairline
                }
            }

            Item {
                id: listSlot
                width: parent.width
                height: parent.height - inputWrap.height - tabsRow.height
                        - (footer.visible ? footer.height : 0)

            ListView {
                id: list
                anchors.fill: parent
                clip: true
                model: root.filtered
                currentIndex: root.selectedIndex
                spacing: 2
                // structural padding: header/footer are part of the content, so
                // model resets and positionViewAt* respect them natively (topMargin
                // lives outside the coordinate system and every reset ignored it)
                header: Item { width: 1; height: 8 }
                footer: Item { width: 1; height: 10 }
                opacity: root.loading ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                add: Transition {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
                }

                delegate: Item {
                    id: rowItem
                    required property var modelData
                    required property int index
                    property bool isDivider: !!(modelData && modelData.divider)
                    readonly property bool hasSub: !isDivider && root.subtitleField.length > 0
                        && modelData && String(modelData[root.subtitleField] || "").length > 0
                    width: list.width
                    height: isDivider ? 36 : (hasSub ? 60 : 44)

                    // ListView owns delegate x/y — the inset highlight must be
                    // an inner rectangle, never an x-offset on the root.
                    Rectangle {
                        visible: !rowItem.isDivider
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        radius: 13
                        color: rowItem.index === root.selectedIndex ? Theme.selection
                             : rowHover.hovered ? Theme.surface
                             : "transparent"
                        border.width: 1
                        border.color: rowItem.index === root.selectedIndex ? Theme.hairline : "transparent"
                    }

                    HoverHandler { id: rowHover; enabled: !rowItem.isDivider }

                    // Non-selectable section heading (palette style).
                    Text {
                        visible: rowItem.isDivider
                        anchors.left: parent.left
                        anchors.leftMargin: 28
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 10
                        text: rowItem.modelData ? String(rowItem.modelData.label || "") : ""
                        color: Theme.fg_muted
                        font.family: notch.sans
                        font.pixelSize: 11
                        font.weight: 600
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.2
                        renderType: Text.NativeRendering
                    }
                    Text {
                        visible: rowItem.isDivider
                        anchors.right: parent.right
                        anchors.rightMargin: 28
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 10
                        text: root.sectionCount(rowItem.index)
                        color: Theme.fg_muted
                        opacity: 0.7
                        font.family: notch.sans
                        font.pixelSize: 11
                        renderType: Text.NativeRendering
                    }

                    Image {
                        id: rowIcon
                        readonly property bool active: !rowItem.isDivider && root.iconField.length > 0
                            && rowItem.modelData
                            && String(rowItem.modelData[root.iconField] || "").length > 0
                        visible: false   // drawn by the MultiEffect below
                        source: active ? rowItem.modelData[root.iconField] : ""
                        width: 16
                        height: 16
                        sourceSize.width: 32
                        sourceSize.height: 32
                        fillMode: Image.PreserveAspectFit
                        anchors.right: parent.right
                        anchors.rightMargin: 28
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    MultiEffect {
                        visible: rowIcon.active
                        source: rowIcon
                        anchors.fill: rowIcon
                        colorization: 1.0
                        colorizationColor: Theme.fg_muted
                    }

                    Text {
                        id: rowGlyph
                        readonly property bool active: !rowItem.isDivider && root.glyphField.length > 0
                            && rowItem.modelData && String(rowItem.modelData[root.glyphField] || "").length > 0
                        visible: active
                        anchors.left: parent.left
                        anchors.leftMargin: 28
                        anchors.verticalCenter: parent.verticalCenter
                        text: active ? String(rowItem.modelData[root.glyphField]) : ""
                        color: (root.glyphColorField && rowItem.modelData && rowItem.modelData[root.glyphColorField])
                            ? rowItem.modelData[root.glyphColorField] : Theme.fg_muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        renderType: Text.NativeRendering
                    }

                    // Highlighted row (e.g. the active worktree): a small accent
                    // dot instead of recoloring the whole label.
                    Rectangle {
                        id: hlDot
                        visible: !rowItem.isDivider && root.highlightField.length > 0
                            && rowItem.modelData && rowItem.modelData[root.highlightField] === true
                        width: 6; height: 6; radius: 3
                        color: Theme.cursor
                        anchors.left: parent.left
                        anchors.leftMargin: 28
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        visible: !rowItem.isDivider
                        anchors.left: rowGlyph.active ? rowGlyph.right : (hlDot.visible ? hlDot.left : parent.left)
                        anchors.leftMargin: rowGlyph.active ? 10 : (hlDot.visible ? 16 : 28)
                        anchors.right: rowIcon.active ? rowIcon.left : parent.right
                        anchors.rightMargin: 28
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            width: parent.width
                            text: rowItem.modelData ? String(rowItem.modelData.label || "?") : "?"
                            color: Theme.fg
                            font.family: notch.sans
                            font.pixelSize: 15
                            font.weight: 500
                            renderType: Text.NativeRendering
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            visible: rowItem.hasSub
                            text: rowItem.modelData && root.subtitleField ? String(rowItem.modelData[root.subtitleField] || "") : ""
                            color: Theme.fg_muted
                            font.family: notch.sans
                            font.pixelSize: 12
                            renderType: Text.NativeRendering
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !rowItem.isDivider
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.selectedIndex = rowItem.index
                            root.activate()
                        }
                    }
                }

                onCurrentIndexChanged: {
                    positionViewAtIndex(currentIndex, ListView.Contain)
                    // Contain stops at the row edge; at the ends, include the spacers
                    if (currentIndex <= root.firstSelectable()) positionViewAtBeginning()
                    else if (currentIndex === count - 1) positionViewAtEnd()
                }
            }

            Item {
                anchors.fill: parent
                opacity: root.loading ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    Repeater {
                        model: 3
                        Rectangle {
                            required property int index
                            width: 7; height: 7; radius: 3.5
                            color: Theme.fg_muted
                            opacity: 0.25
                            SequentialAnimation on opacity {
                                running: root.loading
                                loops: Animation.Infinite
                                PauseAnimation { duration: index * 150 }
                                NumberAnimation { to: 1.0; duration: 300; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 0.25; duration: 300; easing.type: Easing.InOutQuad }
                                PauseAnimation { duration: (2 - index) * 150 }
                            }
                        }
                    }
                }
            }
            }

            Item {
                id: footer
                width: parent.width
                height: 52
                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: Theme.hairline
                }
                Row {
                    id: footerHints
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    KeyCap { text: "j" }
                    KeyCap { text: "k" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "move"
                        color: Theme.fg_muted
                        font.family: notch.sans
                        font.pixelSize: 12
                        renderType: Text.NativeRendering
                    }
                    Item { width: 8; height: 1 }
                    KeyCap { text: "↵" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "open"
                        color: Theme.fg_muted
                        font.family: notch.sans
                        font.pixelSize: 12
                        renderType: Text.NativeRendering
                    }
                    Item { visible: root.tabs.length > 1; width: 8; height: 1 }
                    KeyCap { visible: root.tabs.length > 1; text: "⇥" }
                    Text {
                        visible: root.tabs.length > 1
                        anchors.verticalCenter: parent.verticalCenter
                        text: "switch"
                        color: Theme.fg_muted
                        font.family: notch.sans
                        font.pixelSize: 12
                        renderType: Text.NativeRendering
                    }
                }
                Text {
                    visible: root.altLabel.length > 0
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - footerHints.width - 48)
                    text: root.altLabel
                    color: Theme.fg_muted
                    font.family: notch.sans
                    font.pixelSize: 11
                    renderType: Text.NativeRendering
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                }
            }
        }
    }

}
