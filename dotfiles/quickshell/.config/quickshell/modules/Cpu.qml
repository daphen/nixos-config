import QtQuick
import Quickshell
import Quickshell.Io
import "."
import "../QsLib" as Lib

Item {
    id: root

    property int usage: 0
    property int prevTotal: 0
    property int prevIdle: 0

    implicitWidth: row.implicitWidth + Theme.modulePadH * 2
    implicitHeight: parent ? parent.height : Theme.barHeight

    Process {
        id: proc
        running: true
        command: ["sh", "-c", "head -n1 /proc/stat | awk '{idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8; print idle, total}'"]
        // SplitParser, not StdioCollector: on quickshell 0.3 a reused collector
        // never fires onStreamFinished for the timer's re-runs, so the readout
        // froze at 0%. The parser fires per line on every run.
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).trim().split(/\s+/)
                if (parts.length < 2) return
                const idle = parseInt(parts[parts.length - 2])
                const total = parseInt(parts[parts.length - 1])
                if (isNaN(idle) || isNaN(total)) return
                if (root.prevTotal > 0) {
                    const dt = total - root.prevTotal
                    const di = idle - root.prevIdle
                    if (dt > 0) root.usage = Math.round(100 * (dt - di) / dt)
                }
                root.prevIdle = idle
                root.prevTotal = total
            }
        }
    }

    Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: proc.running = true
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Lib.Icon {
            name: "chip"
            color: Theme.fg
            // the chip's drawn body is compact in its grid — largest bump
            width: 18; height: 18
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.usage + "%"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
