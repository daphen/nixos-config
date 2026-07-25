import QtQuick
import "."

// The active cockpit context, as a single label for the bar pill. Accent when
// its agent is waiting on you; click opens the picker (the overview of every
// context lives there, not in the bar). Colour only — the cockpit surface
// never animates.
Item {
    id: root

    // The bar pills render bg-colored content on the light strip; set false
    // for a dark (notch-style) mount.
    property bool invert: true
    readonly property color base: invert ? Theme.bg : Theme.fg

    readonly property var activeCtx: {
        for (const c of CockpitState.contexts)
            if (c.name === CockpitState.active) return c
        return null
    }

    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight
    visible: activeCtx !== null

    Text {
        id: label
        text: root.activeCtx ? root.activeCtx.name : ""
        color: root.activeCtx && root.activeCtx.state === "awaiting-you"
             ? Theme.cursor : root.base
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        font.weight: Theme.fontWeight
        font.hintingPreference: Font.PreferFullHinting
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: CockpitState.toggle()
    }
}
