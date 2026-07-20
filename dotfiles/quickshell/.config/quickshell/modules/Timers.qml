import QtQuick
import Quickshell
import "."
import "../QsLib" as Lib

// Soonest running countdown; hidden when no timers. Click opens the picker.
Item {
    id: root

    readonly property var soonest: TimerState.items.length > 0 ? TimerState.items[0] : null
    visible: soonest !== null
    implicitWidth: visible ? row.implicitWidth + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Lib.Icon {
            name: "timer-2"
            color: Theme.fg
            width: 15; height: 15
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.soonest
                ? TimerState.fmt(root.soonest.end - TimerState.now)
                  + (TimerState.items.length > 1 ? " +" + (TimerState.items.length - 1) : "")
                : ""
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.weight: Theme.fontWeight
            font.hintingPreference: Font.PreferFullHinting
            renderType: Text.NativeRendering
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    TapHandler { onTapped: TimerState.toggle() }
}
