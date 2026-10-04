import QtQuick

Item {
    id: root

    property string text: ""
    property string iconName: ""
    property int radius: Math.round(height / 2)
    property bool emphasized: false
    property bool primary: true
    property int fontPixelSize: height >= 50 ? 15 : 13
    signal clicked()

    readonly property color topColor: face.topColor
    readonly property color bottomColor: face.bottomColor
    readonly property color contentColor: face.contentColor

    implicitWidth: Math.max(36, label.implicitWidth + (icon.visible ? icon.width + 18 : 0) + 48)
    implicitHeight: 38
    opacity: enabled ? 1 : 0.38
    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.InOutQuad } }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2
        radius: root.radius
        color: Qt.rgba(0, 0, 0, root.primary
            ? (Theme.mode === "dark" ? 0.28 : 0.01)
            : (Theme.mode === "dark" ? 0.20 : 0))
    }

    ButtonSurface {
        id: face
        width: parent.width
        height: parent.height - 2
        radius: root.radius
        primary: root.primary
        inverted: Theme.mode === "dark"
        emphasized: root.emphasized
        y: tap.pressed ? 2 : hover.hovered ? 0 : 1
        Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

        Text {
            id: label
            visible: root.text.length > 0
            anchors.left: root.iconName.length > 0 ? parent.left : undefined
            anchors.leftMargin: root.iconName.length > 0 ? 24 : 0
            anchors.horizontalCenter: root.iconName.length > 0 ? undefined : parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.contentColor
            font.family: Theme.fontFamily
            font.pixelSize: root.fontPixelSize
            font.weight: 500
        }
        Icon {
            id: icon
            visible: root.iconName.length > 0
            anchors.right: root.text.length > 0 ? parent.right : undefined
            anchors.rightMargin: root.text.length > 0 ? 22 : 0
            anchors.horizontalCenter: root.text.length > 0 ? undefined : parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            name: root.iconName
            width: root.height >= 50 ? 18 : 16
            height: width
            color: root.contentColor
        }
    }

    HoverHandler {
        id: hover
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        id: tap
        enabled: root.enabled
        onTapped: root.clicked()
    }
}
