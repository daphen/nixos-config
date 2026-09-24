import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "."
import "../QsLib" as Lib

Item {
    id: root

    readonly property var battery: UPower.displayDevice
    readonly property real percentage: battery ? battery.percentage * 100 : 0
    readonly property real timeToEmpty: battery ? battery.timeToEmpty : 0
    readonly property real timeToFull: battery ? battery.timeToFull : 0
    readonly property bool onBattery: UPower.onBattery
    readonly property string timeText: {
        const draining = timeToEmpty > 0
        const seconds = draining ? timeToEmpty : timeToFull
        if (seconds <= 0) return ""
        const totalMinutes = Math.round(seconds / 60)
        const hours = Math.floor(totalMinutes / 60)
        const minutes = totalMinutes % 60
        const value = (hours > 0 ? hours + "h " : "") + minutes + "m"
        return value + (draining ? " left" : " to full")
    }
    property var deviceRows: []
    readonly property var tooltipRows: {
        const host = Quickshell.env("HYPR_CANVAS_PROFILE") === "deck" ? "Deck" : "Laptop"
        const status = timeText.length ? timeText : onBattery ? "on battery" : "on AC"
        return [{ label: host + " · " + status, detail: Math.round(percentage) + "%",
                   icon: "laptop" }].concat(deviceRows)
    }

    function refreshDevices() {
        if (!batteryQuery.running) batteryQuery.running = true
    }

    Component.onCompleted: refreshDevices()
    Timer { interval: 30000; repeat: true; running: true; onTriggered: root.refreshDevices() }

    Process {
        id: batteryQuery
        command: ["python3", Quickshell.env("HOME") + "/.config/hypr/scripts/battery-hover"]
        stdout: StdioCollector {
            onStreamFinished: {
                const rows = []
                for (const line of this.text.trim().split("\n")) {
                    const parts = line.split("\t")
                    const name = parts[0]
                    if (parts.length !== 2 || (name !== "K:04 left" && name !== "K:04 right" && !name.startsWith("AirPods")))
                        continue
                    const percent = Number(parts[1])
                    if (parts[1] !== "—" && (!Number.isInteger(percent) || percent < 0 || percent > 100))
                        continue
                    rows.push({ label: name, detail: parts[1] === "—" ? "Unavailable" : percent + "%",
                                icon: name.startsWith("AirPods") ? "headset" : "keyboard" })
                }
                root.deviceRows = rows
            }
        }
    }

    implicitWidth: visible ? indicator.implicitWidth + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: battery && battery.isPresent

    readonly property color statusColor: percentage < 15 && UPower.onBattery ? Theme.red
        : percentage < 30 && UPower.onBattery ? Theme.yellow : Theme.fg

    ProgressRingIcon {
        id: indicator
        anchors.centerIn: parent
        progress: root.percentage / 100
        iconName: !UPower.onBattery ? "battery-charging"
                : root.percentage > 95 ? "battery-full"
                : root.percentage > 20 ? "battery-high" : "battery"
        iconColor: root.statusColor
        ringColor: root.statusColor
        iconSize: 16
    }

}
