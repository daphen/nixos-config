import QtQuick
import Quickshell
import Quickshell.Io
import "."
import "../QsLib" as Lib

Item {
    id: root

    property int percentage: 0

    implicitWidth: indicator.implicitWidth + Theme.modulePadH * 2
    implicitHeight: parent ? parent.height : Theme.barHeight

    Behavior on implicitWidth {
        NumberAnimation {
            duration: Lib.Motion.med
            easing.type: Lib.Motion.easeEmphasized
            easing.bezierCurve: Lib.Motion.curveEmphasized
        }
    }

    Process {
        id: proc
        running: true
        command: ["sh", "-c", "awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf \"%d\", (t-a)*100/t}' /proc/meminfo"]
        stdout: StdioCollector {
            onStreamFinished: root.percentage = parseInt(this.text.trim()) || 0
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: proc.running = true
    }

    ProgressRingIcon {
        id: indicator
        anchors.centerIn: parent
        progress: root.percentage / 100
        iconName: "layers-3"
        iconSize: 15
        ringColor: root.percentage >= 90 ? Theme.red
                 : root.percentage >= 75 ? Theme.yellow
                 : Theme.fg
    }

}
