import QtQuick

// Recessed well: the rim shades at the top and catches light at the bottom, and a shadow falls inside the top edge.
Rectangle {
    id: root

    property color base: dark ? "#141414" : "#F7F9FA"
    property real depth: 9
    readonly property bool dark: Theme.mode !== "light"

    radius: height / 2
    gradient: Gradient {
        GradientStop { position: 0; color: root.dark ? Qt.alpha("#000000", 0.30) : Qt.alpha("#000000", 0.14) }
        GradientStop { position: 0.5; color: root.dark ? Qt.alpha("#FFFFFF", 0.05) : Qt.alpha("#000000", 0.08) }
        GradientStop { position: 1; color: root.dark ? Qt.alpha("#FFFFFF", 0.16) : Qt.alpha("#FFFFFF", 0.9) }
    }
    Rectangle {
        id: face
        anchors { fill: parent; margins: 1 }
        radius: Math.max(0, root.radius - 1)
        color: root.base
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.alpha("#000000", root.dark ? 0.22 : 0.05) }
                GradientStop { position: Math.min(1, root.depth / Math.max(1, face.height)); color: Qt.alpha("#000000", root.dark ? 0.08 : 0.01) }
            }
        }
    }
}
