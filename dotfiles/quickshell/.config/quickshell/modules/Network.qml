import QtQuick
import Quickshell
import Quickshell.Io
import "."
import "../QsLib" as Lib

Item {
    id: root

    property string kind: "disconnected"
    property string label: "Disconnected"
    property int strength: 0

    implicitWidth: row.implicitWidth + Theme.modulePadH * 2
    implicitHeight: parent ? parent.height : Theme.barHeight

    Process {
        id: proc
        running: true
        command: ["sh", "-c",
            "line=$(nmcli -t -f ACTIVE,SIGNAL,SSID dev wifi 2>/dev/null | awk -F: '/^yes:/ {sig=$2; ssid=$3; for(i=4;i<=NF;i++) ssid=ssid \":\" $i; print sig, ssid; exit}'); " +
            "if [ -n \"$line\" ]; then echo \"wifi $line\"; else " +
            "  eth=$(nmcli -t -f TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '/^802-3-ethernet:/ {print $2; exit}'); " +
            "  if [ -n \"$eth\" ]; then echo \"eth $eth\"; else echo \"none\"; fi; " +
            "fi"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = this.text.trim()
                if (t.startsWith("wifi ")) {
                    root.kind = "wifi"
                    const m = t.match(/^wifi (\d+) (.*)$/)
                    root.strength = m ? parseInt(m[1]) : 100
                    root.label = m ? m[2] : t.substring(5)
                } else if (t.startsWith("eth ")) {
                    root.kind = "eth"
                    root.label = t.substring(4)
                } else {
                    root.kind = "disconnected"
                    root.label = "Disconnected"
                }
            }
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: proc.running = true
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Lib.Icon {
            // custom thick-stroke wifi fan, arcs by signal strength
            name: root.kind === "eth" ? "plug-2"
                : root.strength > 66 ? "wifi-3"
                : root.strength > 33 ? "wifi-2" : "wifi-1"
            color: Theme.fg
            // signal fan occupies a corner of its grid — biggest optical bump
            width: 17; height: 17
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.label
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
