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
            // bolt whenever on AC (charging, holding at full, or charge-limited)
            name: chargeState === UPowerDeviceState.Charging
                  || chargeState === UPowerDeviceState.FullyCharged
                  || chargeState === UPowerDeviceState.PendingCharge ? "battery-charging"
                : percentage > 95 ? "battery-full"
                : percentage > 20 ? "battery-high" : "battery"
            color: {
                if (chargeState === UPowerDeviceState.Charging
                    || chargeState === UPowerDeviceState.FullyCharged) return Theme.green
                if (percentage < 15) return Theme.red
                if (percentage < 30) return Theme.yellow
                return Theme.fg
            }
            width: 15; height: 15
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Math.round(percentage) + "%"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            renderType: Text.NativeRendering
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
