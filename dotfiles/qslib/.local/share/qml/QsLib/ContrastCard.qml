import QtQuick
import QtQuick.Controls.Material.impl as MaterialImpl

Item {
    id: root

    readonly property bool lightMode: Theme.mode === "light"
    property bool elevated: true
    property color faceTop: lightMode ? "#FBFCFD" : "#121212"
    property color faceUpper: lightMode ? "#FAFBFC" : "#101010"
    property color faceMid: lightMode ? "#F7F9FA" : "#0F0F0F"
    property color faceBottom: lightMode ? "#F4F6F8" : "#0D0D0D"
    property color rimTop: lightMode ? "#FFFFFF" : "#2B2B2B"
    property color rimBottom: lightMode ? "#C9D1D8" : "#222222"
    property color outlineColor: lightMode ? "#C4CBD2" : "#282828"
    property color shadowColor: lightMode ? Qt.rgba(0.12, 0.15, 0.18, 0.14) : "#101010"
    property color contactShadowColor: lightMode ? "#5A5650" : "#101010"
    property int cardRadius: 18
    property int bevelWidth: 2

    MaterialImpl.BoxShadow {
        visible: root.elevated
        source: face
        offsetX: 0
        offsetY: root.lightMode ? 7 : 9
        blurRadius: root.lightMode ? 26 : 22
        spreadRadius: root.lightMode ? -3 : -2
        strength: root.lightMode ? 0.20 : 0.40
        color: root.shadowColor
    }

    MaterialImpl.BoxShadow {
        visible: root.elevated && !root.lightMode
        source: face
        offsetX: 0
        offsetY: root.lightMode ? 2 : 3
        blurRadius: root.lightMode ? 6 : 7
        spreadRadius: -1
        strength: root.lightMode ? 0 : 0.74
        color: root.contactShadowColor
    }

    Rectangle {
        id: face
        anchors.fill: parent
        radius: root.cardRadius
        border.width: 1
        border.color: root.outlineColor
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: root.rimTop }
            GradientStop { position: 1; color: root.rimBottom }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: root.bevelWidth
            radius: Math.max(0, root.cardRadius - root.bevelWidth)
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: root.faceTop }
                GradientStop { position: root.lightMode ? 0.16 : 0.12; color: root.faceUpper }
                GradientStop { position: root.lightMode ? 0.52 : 0.35; color: root.faceMid }
                GradientStop { position: root.lightMode ? 1 : 0.70; color: root.faceBottom }
                GradientStop { position: 1; color: root.faceBottom }
            }
        }
    }
}
