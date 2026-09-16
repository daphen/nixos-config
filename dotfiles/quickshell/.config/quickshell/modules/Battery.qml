import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "."
import "../QsLib" as Lib

Item {
    id: root

    readonly property var battery: UPower.displayDevice
    readonly property real percentage: battery ? battery.percentage * 100 : 0
    readonly property real powerDraw: battery ? Math.abs(battery.changeRate) : 0
    readonly property bool onBattery: UPower.onBattery
    // Don't name this `state` — Item.state is a built-in string property and
    // shadowing it makes the enum comparison below silently fail.
    readonly property int chargeState: battery ? battery.state : 0

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
