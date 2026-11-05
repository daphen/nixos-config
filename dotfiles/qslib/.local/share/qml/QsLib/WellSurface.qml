import QtQuick

// Recessed field: the rim shades at the top and catches light at the bottom, and a shadow falls inside the top edge.
Rectangle {
    id: root

    property color base: dark ? "#141414" : "#F7F9FA"
    property real depth: 12
    readonly property bool dark: Theme.mode !== "light"

    radius: height / 2
    gradient: Gradient {
        GradientStop { position: 0; color: root.dark ? Qt.alpha("#000000", 0.55) : Qt.alpha("#000000", 0.20) }
        GradientStop { position: 0.5; color: root.dark ? Qt.alpha("#FFFFFF", 0.07) : Qt.alpha("#000000", 0.10) }
        GradientStop { position: 1; color: root.dark ? Qt.alpha("#FFFFFF", 0.20) : Qt.alpha("#000000", 0.04) }
    }
    Rectangle {
        anchors { fill: parent; margins: 1 }
        radius: Math.max(0, root.radius - 1)
        color: Qt.tint(root.base, Qt.alpha("#000000", root.dark ? 0.30 : 0.035))
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            readonly property real stop: Math.min(0.5, root.depth / Math.max(1, height))
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.alpha("#000000", root.dark ? 0.45 : 0.09) }
                GradientStop { position: parent.stop; color: Qt.alpha("#000000", root.dark ? 0.10 : 0.02) }
                GradientStop { position: Math.min(1, parent.stop * 2.2); color: "transparent" }
            }
        }
    }
}
