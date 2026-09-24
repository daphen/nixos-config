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

    readonly property color topColor: primary
        ? (Theme.mode === "dark" ? "#FAFAFA" : "#3D3D3D")
        : (Theme.mode === "dark" ? Theme.surface3 : "#FFFFFF")
    readonly property color bottomColor: primary
        ? (Theme.mode === "dark" ? "#DDDDDD" : "#0E0E0E")
        : (Theme.mode === "dark" ? Theme.surface1 : Theme.surface2)
    readonly property color contentColor: primary
        ? (Theme.mode === "dark" ? "#2D2D2B" : "#FAFAFA")
        : Theme.fg

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

    Rectangle {
        id: face
        width: parent.width
        height: parent.height - 2
        radius: root.radius
        y: tap.pressed ? 2 : hover.hovered ? 0 : 1
        border.width: 1
        border.color: root.primary
            ? (Theme.mode === "dark"
                ? (root.emphasized ? "#969696" : "#AAAAAA")
                : Qt.rgba(0, 0, 0, root.emphasized ? 0.62 : 0.50))
            : (Theme.mode === "dark" ? Theme.hairline : "#C8C8C6")
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop {
                position: 0
                color: root.primary
                    ? (Theme.mode === "dark" ? "#D8D8D8" : "#666666")
                    : (Theme.mode === "dark" ? Theme.surface3 : "#F5F5F3")
            }
            GradientStop {
                position: 1
                color: root.primary
                    ? (Theme.mode === "dark" ? "#A9A9A9" : "#333333")
                    : (Theme.mode === "dark" ? Theme.surface0 : "#D8D8D6")
            }
        }
        Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Math.max(0, face.radius - 2)
            border.width: 0
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: root.topColor }
                GradientStop { position: 1; color: root.bottomColor }
            }
        }

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
