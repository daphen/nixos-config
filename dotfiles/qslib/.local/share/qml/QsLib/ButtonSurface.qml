import QtQuick

Rectangle {
    id: root
    property bool primary: true
    property bool inverted: false
    property bool emphasized: false
    readonly property color topColor: primary
        ? (inverted ? "#FAFAFA" : "#3D3D3D")
        : (Theme.mode === "dark" ? Theme.surface3 : "#FFFFFF")
    readonly property color bottomColor: primary
        ? (inverted ? "#DDDDDD" : "#0E0E0E")
        : (Theme.mode === "dark" ? Theme.surface1 : Theme.surface2)
    readonly property color contentColor: primary
        ? (inverted ? "#2D2D2B" : "#FAFAFA") : Theme.fg

    border.width: 1
    border.color: primary
        ? (inverted ? (emphasized ? "#969696" : "#AAAAAA") : Qt.rgba(0, 0, 0, emphasized ? 0.62 : 0.50))
        : (Theme.mode === "dark" ? Theme.hairline : "#C8C8C6")
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0; color: root.primary ? (root.inverted ? "#D8D8D8" : "#666666") : (Theme.mode === "dark" ? Theme.surface3 : "#F5F5F3") }
        GradientStop { position: 1; color: root.primary ? (root.inverted ? "#A9A9A9" : "#333333") : (Theme.mode === "dark" ? Theme.surface0 : "#D8D8D6") }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: Math.max(0, root.radius - 2)
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: root.topColor }
            GradientStop { position: 1; color: root.bottomColor }
        }
    }
}
