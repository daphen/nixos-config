import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "."

Item {
    id: root
    readonly property var sink: Pipewire.defaultAudioSink
    property real brightness: -1
    readonly property bool open: ControlCenterState.open
    visible: open
    implicitHeight: 154
    focus: open
    Keys.onEscapePressed: ControlCenterState.open = false

    PwObjectTracker { objects: [root.sink] }

    function refreshBrightness() { brightnessRead.running = true }
    function setBrightness(value) {
        Quickshell.execDetached(["brightnessctl", "-q", "set", Math.max(1, Math.round(value * 100)) + "%"])
        refreshDelay.restart()
    }
    onOpenChanged: if (open) {
        refreshBrightness()
        Qt.callLater(() => controls.itemAt(0).slider.forceActiveFocus())
    }
    Timer { running: root.open; repeat: true; interval: 1000; onTriggered: root.refreshBrightness() }
    Timer { id: refreshDelay; interval: 150; onTriggered: root.refreshBrightness() }
    Process {
        id: brightnessRead
        command: ["brightnessctl", "-m", "info"]
        stdout: StdioCollector {
            onStreamFinished: {
                const fields = text.trim().split(",")
                if (fields.length >= 4) root.brightness = parseFloat(fields[3]) / 100
            }
        }
    }

    component ControlSlider: Slider {
        from: 0; to: 1; stepSize: 0.05; snapMode: Slider.SnapAlways
        implicitHeight: 44
        background: Rectangle {
            x: parent.leftPadding; y: parent.topPadding + parent.availableHeight / 2 - height / 2
            width: parent.availableWidth; height: 6; radius: 3; color: Theme.surface2
            Rectangle { width: parent.width * parent.parent.visualPosition; height: parent.height; radius: 3; color: Theme.cursor }
        }
        handle: Rectangle {
            x: parent.leftPadding + parent.visualPosition * (parent.availableWidth - width)
            y: parent.topPadding + parent.availableHeight / 2 - height / 2
            width: 18; height: 18; radius: 9; color: Theme.fg
        }
    }

    Column {
        anchors { fill: parent; margins: 14 }
        spacing: 8
        Repeater {
            id: controls
            model: [
                { label: "Brightness", icon: "󰃠" },
                { label: "Volume", icon: "󰕾" }
            ]
            Rectangle {
                required property var modelData
                required property int index
                property alias slider: slider
                width: parent.width; height: 59; radius: 15
                color: Theme.surface0; border.width: 1; border.color: Theme.hairline
                Text {
                    anchors { left: parent.left; leftMargin: 15; verticalCenter: parent.verticalCenter }
                    text: parent.modelData.icon; color: Theme.fg; font.family: Theme.iconFontFamily; font.pixelSize: 17
                }
                Text {
                    anchors { left: parent.left; leftMargin: 44; verticalCenter: parent.verticalCenter }
                    text: parent.modelData.label; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 14
                }
                ControlSlider {
                    id: slider
                    anchors { right: parent.right; rightMargin: 15; verticalCenter: parent.verticalCenter }
                    width: Math.min(250, parent.width * 0.48)
                    enabled: parent.index === 0 ? root.brightness >= 0 : !!(root.sink && root.sink.audio)
                    onEnabledChanged: if (enabled && root.open && parent.index === 0) forceActiveFocus()
                    Keys.onUpPressed: controls.itemAt(0).slider.forceActiveFocus()
                    Keys.onDownPressed: controls.itemAt(1).slider.forceActiveFocus()
                    Binding on value {
                        when: !slider.pressed
                        value: slider.parent.index === 0 ? root.brightness : (root.sink && root.sink.audio ? root.sink.audio.volume : 0)
                    }
                    onMoved: {
                        if (parent.index === 0) root.setBrightness(value)
                        else if (root.sink && root.sink.audio) root.sink.audio.volume = value
                    }
                }
            }
        }
    }
}
