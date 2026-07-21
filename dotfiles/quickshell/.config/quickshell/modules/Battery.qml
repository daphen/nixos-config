import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "."
import "../QsLib" as Lib

Item {
    id: root

    readonly property var battery: UPower.displayDevice
    readonly property real percentage: battery ? battery.percentage * 100 : 0
    // Don't name this `state` — Item.state is a built-in string property and
    // shadowing it makes the enum comparison below silently fail.
    readonly property int chargeState: battery ? battery.state : 0

    implicitWidth: visible ? row.implicitWidth + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: battery && battery.isPresent

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Lib.Icon {
            // bolt whenever on AC — read the AC line (UPower.onBattery), not
            // the battery's charge state: a full battery on AC reports
            // "Discharging" (trickle) on this EC and the bolt vanished
            name: !UPower.onBattery ? "battery-charging"
                : percentage > 95 ? "battery-full"
                : percentage > 20 ? "battery-high" : "battery"
            // ink like the neighbors — the bolt already communicates AC;
            // color only escalates for genuinely low battery
            color: {
                if (percentage < 15 && UPower.onBattery) return Theme.red
                if (percentage < 30 && UPower.onBattery) return Theme.yellow
                return Theme.fg
            }
            // the battery glyph is squat in its grid — render a touch larger
            // so it optically matches the taller neighbors
            width: 17; height: 17
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Math.round(percentage) + "%"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
