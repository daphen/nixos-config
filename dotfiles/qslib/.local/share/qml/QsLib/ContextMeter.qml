import QtQuick

// Cockpit's context meter: a recessed well holding a drifting field that fills and shifts green → sky → orange → red.
Item {
    id: root

    property real percent: 0
    property color surface: dark ? "#141414" : "#F7F9FA"
    readonly property color ink: percent < 50 ? Theme.green : percent < 70 ? Theme.sky : percent < 90 ? Theme.orange : Theme.red
    readonly property bool dark: Theme.mode !== "light"
    property int fieldMargin: 3
    property int fillDuration: 400

    implicitWidth: 140
    implicitHeight: 22

    // Recessed well: the rim shades at the top and catches light at the bottom.
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        gradient: Gradient {
            GradientStop { position: 0; color: root.dark ? Qt.alpha("#000000", 0.30) : Qt.alpha("#000000", 0.14) }
            GradientStop { position: 0.5; color: root.dark ? Qt.alpha("#FFFFFF", 0.05) : Qt.alpha("#000000", 0.08) }
            GradientStop { position: 1; color: root.dark ? Qt.alpha("#FFFFFF", 0.16) : Qt.alpha("#FFFFFF", 0.9) }
        }
        Rectangle {
            anchors { fill: parent; margins: 1 }
            radius: height / 2
            color: root.surface
            Rectangle {
                anchors.fill: parent
                radius: height / 2
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.alpha("#000000", root.dark ? 0.22 : 0.05) }
                    GradientStop { position: 0.45; color: Qt.alpha("#000000", root.dark ? 0.08 : 0.01) }
                }
            }
        }
    }
    ShaderEffect {
        objectName: "contextField"
        anchors { fill: parent; margins: root.fieldMargin }
        fragmentShader: Qt.resolvedUrl("context-field.frag.qsb")
        readonly property real hu: root.ink.hslHue < 0 ? 0 : root.ink.hslHue
        readonly property real sat: Math.min(1, Math.max(0.75, root.ink.hslSaturation))
        readonly property real lift: root.dark ? 0 : 0.047
        readonly property bool warm: hu < 0.45
        readonly property bool orange: hu < 0.17
        readonly property real coolLift: 0.10 * Math.max(0, Math.min(1, (hu - 0.565) / 0.06))
        function phase(period) { return ((OrbClock.now * 0.9) % period) / period * 2 * Math.PI }
        property real ph1: phase(47000)
        property real ph2: phase(61000) + 1.3
        property real ph3: phase(83000) + 2.9
        property real ph4: phase(29000) + 4.2
        // ThinkingOrb's palette minus its pale crest, so the long pill stays calm.
        property color colA: orange ? Qt.hsla((hu - 0.027 + 1) % 1, sat, 0.359 + lift, 1)
            : Qt.hsla((hu + (warm ? 0.02 : 0.03)) % 1, sat * 0.60, (root.dark ? 0.24 : 0.30) + coolLift * 0.6, 1)
        property color colB: orange ? Qt.hsla(hu, sat * 0.867, 0.55 + lift, 1)
            : Qt.hsla(hu, sat * (warm ? 0.70 : 0.55), (root.dark ? 0.52 : 0.58) + coolLift, 1)
        property color colC: colB
        property real angle: -0.76
        property real bandX: 3
        property real bandY: 1.2
        property real warp: 0.8
        property real gain: 0.54
        property real feather: 0.96
        property real bright: 0.55
        property real swirl: 1.2
        property real plasma: 0.05
        property real fill: root.percent / 100
        property real aspect: width / height
        property real pixel: 2 / height
        Behavior on fill { enabled: root.fillDuration > 0; NumberAnimation { duration: root.fillDuration; easing.type: Easing.OutCubic } }
        Behavior on colA { ColorAnimation { duration: 650 } }
        Behavior on colB { ColorAnimation { duration: 650 } }
    }
}
