import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "."

// Countdown timers. Type a duration + enter to start ("5 tea" · "25m" ·
// "1h10 focus" · "90s"); running timers list below with live countdowns.
// Enter on an empty query (or ctrl+w) cancels the selected timer.
PanelWindow {
    id: root

    readonly property bool open: TimerState.open
    property int selectedIndex: 0
    readonly property string query: search ? search.text : ""

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

    function close() { TimerState.open = false }

    function activate() {
        const q = query.trim()
        if (q.length > 0) {
            const p = TimerState.parseSpec(q)
            if (p) { TimerState.add(p.ms, p.label); root.close() }
            return
        }
        // empty query: enter cancels the selected running timer
        if (TimerState.items.length === 0) return
        TimerState.cancel(Math.max(0, Math.min(selectedIndex, TimerState.items.length - 1)))
        if (selectedIndex >= TimerState.items.length) selectedIndex = Math.max(0, TimerState.items.length - 1)
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
        width: 560
        height: 320
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
                placeholderText: "5 tea  ·  25m  ·  1h10 focus  ·  90s"
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
                    } else if (event.key === Qt.Key_W && (event.modifiers & Qt.ControlModifier)) {
                        if (TimerState.items.length > 0) {
                            TimerState.cancel(Math.max(0, Math.min(root.selectedIndex, TimerState.items.length - 1)))
                            if (root.selectedIndex >= TimerState.items.length) root.selectedIndex = Math.max(0, TimerState.items.length - 1)
                        }
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                        if (TimerState.items.length > 0) root.selectedIndex = Math.min(root.selectedIndex + 1, TimerState.items.length - 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                        if (TimerState.items.length > 0) root.selectedIndex = Math.max(root.selectedIndex - 1, 0)
                        event.accepted = true
                    }
                }
            }

            ListView {
                id: list
                width: parent.width
                height: parent.height - search.height - footer.height - parent.spacing * 2
                clip: true
                model: TimerState.items
                currentIndex: root.selectedIndex
                spacing: 2

                Text {
                    visible: TimerState.items.length === 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 18
                    text: "No timers running."
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    renderType: Text.NativeRendering
                }

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
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData && modelData.label ? String(modelData.label) : "timer"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.weight: Theme.fontWeight
                        renderType: Text.NativeRendering
                        elide: Text.ElideRight
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData ? TimerState.fmt(modelData.end - TimerState.now) : ""
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        renderType: Text.NativeRendering
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedIndex = index
                    }
                }

                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            }

            Text {
                id: footer
                width: parent.width
                text: "duration [label] + enter: start  ·  enter / ctrl+w: cancel selected  ·  esc: close"
                color: Theme.fg_muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                renderType: Text.NativeRendering
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
