import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "."
import "../QsLib" as Lib

Item {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property real volume: sink && sink.audio ? sink.audio.volume : 0
    readonly property bool muted: sink && sink.audio ? sink.audio.muted : false
    readonly property bool bluetooth: {
        if (!sink) return false
        const n = (sink.name || "").toLowerCase()
        const d = (sink.description || "").toLowerCase()
        return n.indexOf("bluez") >= 0 || n.indexOf("bluetooth") >= 0
            || d.indexOf("bluetooth") >= 0 || d.indexOf("airpods") >= 0
    }

    implicitWidth: visible ? indicator.implicitWidth + Theme.modulePadH * 2 : 0
    implicitHeight: parent ? parent.height : Theme.barHeight
    visible: sink !== null

    // Required for Quickshell to subscribe to sink property changes.
    PwObjectTracker {
        objects: [sink]
    }

    ProgressRingIcon {
        id: indicator
        anchors.centerIn: parent
        progress: root.muted ? 0 : Math.min(1, root.volume)
        iconName: root.bluetooth ? "headphones" : (root.muted || root.volume <= 0.33) ? "volume" : "volume-up"
        iconColor: root.muted ? Theme.red : Theme.fg
        ringColor: root.muted ? Theme.red : Theme.fg
        iconSize: 14
        iconVerticalOffset: root.bluetooth ? 1 : 0
    }
}
