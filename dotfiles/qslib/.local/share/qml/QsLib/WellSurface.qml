import QtQuick

// Recessed well. The default is the context meter's recipe: rim shaded at the top and lit at
// the bottom, shadow inside the top edge. `field` is the text-input recipe: shadows inside both
// edges, and in dark mode a light hairline all round, since a black top edge vanishes there.
Rectangle {
    id: root

    property color base: dark ? "#141414" : "#F7F9FA"
    property bool field: false
    property real depth: field ? (dark ? 16 : 14) : 9
    property real emphasis: 1
    Behavior on emphasis { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    readonly property bool dark: Theme.mode !== "light"
    property real topShade: field ? (dark ? 0.18 : 0.021) : (dark ? 0.22 : 0.05)
    property real bottomShade: field ? (dark ? 0.16 : 0.021) : 0
    function ink(c, a) { return Qt.alpha(c, Math.min(1, a * emphasis)) }
    function rim(meter, input) { return field ? input : meter }

    radius: height / 2
    gradient: Gradient {
        GradientStop { position: 0; color: root.dark ? root.rim(root.ink("#000000", 0.30), root.ink("#FFFFFF", 0.08)) : root.ink("#000000", root.rim(0.14, 0.11)) }
        GradientStop { position: 0.5; color: root.dark ? root.rim(root.ink("#FFFFFF", 0.05), root.ink("#FFFFFF", 0.06)) : root.ink("#000000", root.rim(0.08, 0.064)) }
        GradientStop { position: 1; color: root.dark ? root.ink("#FFFFFF", root.rim(0.16, 0.11)) : root.ink("#FFFFFF", root.rim(0.9, 0.72)) }
    }
    Rectangle {
        id: face
        anchors { fill: parent; margins: 1 }
        radius: Math.max(0, root.radius - 1)
        color: root.field && root.dark ? Qt.tint(root.base, Qt.alpha("#000000", 0.35)) : root.base
        readonly property real fade: Math.min(root.field ? 0.45 : 1, root.depth / Math.max(1, height))
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: !root.field
            gradient: Gradient {
                GradientStop { position: 0; color: root.ink("#000000", root.topShade) }
                GradientStop { position: face.fade; color: root.ink("#000000", root.dark ? 0.08 : 0.01) }
            }
        }
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: root.field
            gradient: Gradient {
                GradientStop { position: 0; color: root.ink("#000000", root.topShade) }
                GradientStop { position: face.fade; color: root.ink("#000000", root.topShade * 0.3) }
                GradientStop { position: Math.min(0.5, face.fade * 1.8); color: "transparent" }
                GradientStop { position: Math.max(0.5, 1 - face.fade * 1.8); color: "transparent" }
                GradientStop { position: 1 - face.fade; color: root.ink("#000000", root.bottomShade * 0.3) }
                GradientStop { position: 1; color: root.ink("#000000", root.bottomShade) }
            }
        }
    }
}
