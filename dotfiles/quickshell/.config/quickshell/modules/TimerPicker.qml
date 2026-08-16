import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "."
import "../QsLib" as Lib

// Interactive countdown dial (house notch chrome, no text input):
// h/l picks the H:MM:SS segment, j/k or scroll adjusts it, digits type
// into it microwave-style, preset pills load common durations, Enter
// starts. Running timers below: Ctrl+J/K selects, Ctrl+W cancels.
PanelWindow {
    id: root

    readonly property bool open: TimerState.open
    function close() { TimerState.open = false }

    // dial state ────────────────────────────────────────────────────
    property int hrs: 0
    property int mins: 10
    property int secs: 0
    property int seg: 1          // 0 h · 1 m · 2 s
    property int selectedTimer: 0
    readonly property int totalMs: (hrs * 3600 + mins * 60 + secs) * 1000
    // home-row quick keys — clear of the dial's h/j/k/l, digits, and i
    readonly property var presets: [
        { key: "a", label: "5m",  ms: 5 * 60000 },
        { key: "s", label: "10m", ms: 10 * 60000 },
        { key: "d", label: "25m", ms: 25 * 60000 },
        { key: "f", label: "45m", ms: 45 * 60000 },
        { key: "g", label: "1h",  ms: 3600000 },
    ]

    function loadMs(ms) {
        const t = Math.floor(ms / 1000)
        hrs = Math.floor(t / 3600); mins = Math.floor((t % 3600) / 60); secs = t % 60
    }
    function stepSeg(dir, big) {
        const d = dir * (big ? (seg === 0 ? 1 : 5) : 1)
        if (seg === 0) hrs = Math.max(0, Math.min(99, hrs + d))
        else if (seg === 1) mins = (mins + d + 60) % 60
        else secs = (secs + d + 60) % 60
    }
    function typeDigit(n) {
        if (seg === 0) hrs = (hrs * 10 + n) % 100
        else if (seg === 1) mins = (mins * 10 + n) % 100 % 60
        else secs = (secs * 10 + n) % 100 % 60
    }
    function start() {
        if (totalMs <= 0) return
        TimerState.add(totalMs, labelField.text.trim())
        root.close()
    }

    property bool active: false
    visible: active
    onOpenChanged: {
        if (open) {
            closeDelay.stop(); active = true
            seg = 1; selectedTimer = 0
            labelField.text = ""
            keys.forceActiveFocus()
        } else closeDelay.restart()
    }
    Timer { id: closeDelay; interval: 300; onTriggered: root.active = false }

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-picker"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property color panelBorder: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b,
                                                 Theme.mode === "light" ? 0.15 : 0.10)
    component KeyCap: Lib.KeyCap { anchors.verticalCenter: parent.verticalCenter }

    Rectangle {
        id: dim
        anchors.fill: parent
        color: "#000000"
        opacity: root.open ? 0.35 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Item {
        id: keys
        focus: true
        Keys.onPressed: event => {
            const ctrl = event.modifiers & Qt.ControlModifier
            const shift = event.modifiers & Qt.ShiftModifier
            const k = event.key
            event.accepted = true
            if (k === Qt.Key_Escape) root.close()
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.start()
            else if (ctrl && k === Qt.Key_J) {
                if (TimerState.items.length > 0)
                    root.selectedTimer = Math.min(root.selectedTimer + 1, TimerState.items.length - 1)
            } else if (ctrl && k === Qt.Key_K) {
                if (TimerState.items.length > 0)
                    root.selectedTimer = Math.max(root.selectedTimer - 1, 0)
            } else if (ctrl && k === Qt.Key_W) {
                if (TimerState.items.length > 0) {
                    TimerState.cancel(Math.max(0, Math.min(root.selectedTimer, TimerState.items.length - 1)))
                    if (root.selectedTimer >= TimerState.items.length)
                        root.selectedTimer = Math.max(0, TimerState.items.length - 1)
                }
            }
            else if (k === Qt.Key_H || k === Qt.Key_Left)  root.seg = Math.max(0, root.seg - 1)
            else if (k === Qt.Key_L || k === Qt.Key_Right) root.seg = Math.min(2, root.seg + 1)
            else if (k === Qt.Key_K || k === Qt.Key_Up)    root.stepSeg(1, shift)
            else if (k === Qt.Key_J || k === Qt.Key_Down)  root.stepSeg(-1, shift)
            else if (k >= Qt.Key_0 && k <= Qt.Key_9)       root.typeDigit(k - Qt.Key_0)
            else if (k === Qt.Key_I)                       labelField.forceActiveFocus()
            else if (k === Qt.Key_A) root.loadMs(root.presets[0].ms)
            else if (k === Qt.Key_S) root.loadMs(root.presets[1].ms)
            else if (k === Qt.Key_D) root.loadMs(root.presets[2].ms)
            else if (k === Qt.Key_F) root.loadMs(root.presets[3].ms)
            else if (k === Qt.Key_G) root.loadMs(root.presets[4].ms)
            else event.accepted = false
        }
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
        width: 560
        height: presetsRow.height + dialWrap.height + labelWrap.height + runningWrap.height + footer.height
        color: Theme.bg
        radius: 24
        border.color: root.panelBorder
        border.width: 1
        clip: true
        scale: root.open ? 1.0 : 0.96
        opacity: root.open ? 1.0 : 0.0
        Behavior on scale { NumberAnimation { duration: 190; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0] } }
        Behavior on opacity { NumberAnimation { duration: 190; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0] } }

        readonly property string sans: Theme.fontFamily

        Column {
            anchors.fill: parent

            // ── presets + esc ─────────────────────────────────────
            Item {
                id: presetsRow
                width: parent.width
                height: 56

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: root.presets
                        Rectangle {
                            required property var modelData
                            width: pRow.implicitWidth + 18
                            height: 28
                            radius: 10
                            color: pHov.hovered ? Theme.surface : Theme.surface1
                            border.color: Theme.hairline
                            border.width: 1
                            Row {
                                id: pRow
                                anchors.centerIn: parent
                                spacing: 6
                                Lib.KeyCap {
                                    small: true
                                    text: parent.parent.modelData.key
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: parent.parent.modelData.label
                                    color: Theme.fg
                                    font.family: notch.sans
                                    font.pixelSize: 13
                                    font.weight: 500
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            HoverHandler { id: pHov }
                            TapHandler { onTapped: root.loadMs(parent.modelData.ms) }
                        }
                    }
                }

                KeyCap {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: "esc"
                    TapHandler { onTapped: root.close() }
                }
            }

            // ── the dial ──────────────────────────────────────────
            Item {
                id: dialWrap
                width: parent.width
                height: 118

                component SegTile: Column {
                    id: segCol
                    property int idx: 0
                    property string unit: ""
                    readonly property bool isSeg: root.seg === idx
                    readonly property int value: idx === 0 ? root.hrs : idx === 1 ? root.mins : root.secs
                    spacing: 6

                    Rectangle {
                        width: 92
                        height: 72
                        radius: 13
                        color: segCol.isSeg ? Theme.selection
                             : segHov.hovered ? Theme.surface : Theme.surface1
                        border.width: 1
                        border.color: Theme.hairline
                        Text {
                            anchors.centerIn: parent
                            text: (segCol.value < 10 ? "0" : "") + segCol.value
                            color: Theme.fg
                            font.family: notch.sans
                            font.pixelSize: 40
                            font.weight: 600
                        }
                        HoverHandler { id: segHov }
                        TapHandler { onTapped: root.seg = segCol.idx }
                        WheelHandler {
                            onWheel: ev => {
                                root.seg = segCol.idx
                                root.stepSeg(ev.angleDelta.y > 0 ? 1 : -1, false)
                            }
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: segCol.unit
                        color: segCol.isSeg ? Theme.fg : Theme.fg_muted
                        font.family: notch.sans
                        font.pixelSize: 11
                        font.weight: 600
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.2
                    }
                }
                component Colon: Text {
                    // sit at tile-center height (tile 72 + gap 6 + unit line below)
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -12
                    text: ":"
                    color: Theme.fg_muted
                    font.family: notch.sans
                    font.pixelSize: 30
                    font.weight: 600
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 10
                    SegTile { idx: 0; unit: "hours" }
                    Colon {}
                    SegTile { idx: 1; unit: "min" }
                    Colon {}
                    SegTile { idx: 2; unit: "sec" }
                }
            }

            // ── name (optional): i focuses, esc back to dial ──────
            Item {
                id: labelWrap
                width: parent.width
                height: 54

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    anchors.topMargin: 4
                    anchors.bottomMargin: 12
                    radius: 13
                    color: Theme.surface1
                    border.width: 1
                    border.color: labelField.activeFocus ? Theme.fg_muted : Theme.hairline

                    Lib.KeyCap {
                        id: nameCap
                        visible: !labelField.activeFocus
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "i"
                        TapHandler { onTapped: labelField.forceActiveFocus() }
                    }

                    TextField {
                        id: labelField
                        anchors.left: parent.left
                        anchors.right: nameCap.visible ? nameCap.left : parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        verticalAlignment: TextInput.AlignVCenter
                        placeholderText: "unnamed"
                        color: Theme.fg
                        placeholderTextColor: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.45)
                        font.family: notch.sans
                        font.pixelSize: 14
                        background: null
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                keys.forceActiveFocus(); event.accepted = true
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                root.start(); event.accepted = true
                            }
                        }
                    }
                }
                TapHandler { onTapped: labelField.forceActiveFocus() }
            }

            // ── running timers ────────────────────────────────────
            Item {
                id: runningWrap
                width: parent.width
                height: TimerState.items.length > 0 ? 36 + Math.min(4, TimerState.items.length) * 46 + 16 : 0
                visible: height > 0

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.top: parent.top
                    anchors.topMargin: 14
                    text: "Running"
                    color: Theme.fg_muted
                    font.family: notch.sans
                    font.pixelSize: 11
                    font.weight: 600
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.2
                }

                ListView {
                    anchors.fill: parent
                    anchors.topMargin: 36
                    anchors.bottomMargin: 16
                    clip: true
                    model: TimerState.items
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: 44

                        Rectangle {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            radius: 13
                            color: index === root.selectedTimer ? Theme.selection
                                 : rHov.hovered ? Theme.surface : "transparent"
                            border.width: 1
                            border.color: index === root.selectedTimer ? Theme.hairline : "transparent"
                        }
                        HoverHandler { id: rHov }
                        TapHandler { onTapped: root.selectedTimer = index }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 28
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData && modelData.label ? String(modelData.label) : "timer"
                            color: Theme.fg
                            font.family: notch.sans
                            font.pixelSize: 15
                            font.weight: 500
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 28
                            anchors.verticalCenter: parent.verticalCenter
                            text: !modelData ? ""
                                : modelData.rang ? "rang " + TimerState.fmt(TimerState.now - modelData.end) + " ago"
                                : TimerState.fmt(modelData.end - TimerState.now)
                            color: modelData && modelData.rang ? Theme.red : Theme.fg_muted
                            font.family: notch.sans
                            font.pixelSize: 13
                        }
                    }
                }
            }

            // ── footer ────────────────────────────────────────────
            Item {
                id: footer
                width: parent.width
                height: 52
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    anchors.rightMargin: 1
                    anchors.bottomMargin: 1
                    color: Theme.surface0
                    bottomLeftRadius: 23
                    bottomRightRadius: 23
                }
                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: Theme.hairline
                }
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    KeyCap { text: "h" }
                    KeyCap { text: "l" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "field"
                        color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                        font.family: notch.sans; font.pixelSize: 12
                    }
                    Item { width: 8; height: 1 }
                    KeyCap { text: "j" }
                    KeyCap { text: "k" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "adjust"
                        color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                        font.family: notch.sans; font.pixelSize: 12
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    KeyCap { text: "↵" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "start"
                        color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                        font.family: notch.sans; font.pixelSize: 12
                    }
                    Item { visible: TimerState.items.length > 0; width: 8; height: 1 }
                    KeyCap { visible: TimerState.items.length > 0; text: "ctrl" }
                    KeyCap { visible: TimerState.items.length > 0; text: "j" }
                    KeyCap { visible: TimerState.items.length > 0; text: "k" }
                    Text {
                        visible: TimerState.items.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: "pick"
                        color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                        font.family: notch.sans; font.pixelSize: 12
                    }
                    Item { visible: TimerState.items.length > 0; width: 8; height: 1 }
                    KeyCap { visible: TimerState.items.length > 0; text: "ctrl" }
                    KeyCap { visible: TimerState.items.length > 0; text: "w" }
                    Text {
                        visible: TimerState.items.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: "cancel"
                        color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                        font.family: notch.sans; font.pixelSize: 12
                    }
                }
            }
        }
    }
}
