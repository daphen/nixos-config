import QtQuick

Rectangle {
    id: root
    property bool shown: false
    property string text: ""
    implicitWidth: label.implicitWidth + 20
    implicitHeight: 30
    visible: shown || opacity > 0
    opacity: shown ? 1 : 0
    radius: 10
    color: Theme.mode === "dark" ? "#0F0F0F" : "#F7F9FA"
    border { width: 1; color: Theme.hairline }
    z: 10
    Behavior on opacity {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
    Behavior on y {
        NumberAnimation {
            duration: Motion.med
            easing.type: Motion.easeEmphasized
            easing.bezierCurve: Motion.curveEmphasized
        }
    }
    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        textFormat: Text.PlainText
        color: Theme.fg
        font { family: Theme.fontFamily; pixelSize: Theme.fontSize - 1; weight: Theme.fontWeight }
    }
}
