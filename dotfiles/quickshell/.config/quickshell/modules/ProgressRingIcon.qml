import QtQuick
import QtQuick.Shapes
import "."
import "../QsLib" as Lib

Item {
    id: root

    property real progress: 0
    property string iconName: ""
    property color ringColor: Theme.fg
    property color iconColor: ringColor
    property color trackColor: Theme.hairline
    property real strokeWidth: 2
    property real iconSize: 15
    property real iconVerticalOffset: 0

    implicitWidth: 30
    implicitHeight: 30

    Behavior on progress {
        NumberAnimation {
            duration: Lib.Motion.med
            easing.type: Easing.InOutQuad
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.trackColor
            strokeWidth: root.strokeWidth
            capStyle: ShapePath.RoundCap
            fillColor: "transparent"

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: Math.min(root.width, root.height) / 2 - root.strokeWidth / 2
                radiusY: radiusX
                startAngle: 135
                sweepAngle: 270
                moveToStart: true
            }
        }

        ShapePath {
            strokeColor: root.progress > 0 ? root.ringColor : "transparent"
            strokeWidth: root.strokeWidth
            capStyle: ShapePath.RoundCap
            fillColor: "transparent"

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: Math.min(root.width, root.height) / 2 - root.strokeWidth / 2
                radiusY: radiusX
                startAngle: 135
                sweepAngle: 270 * Math.max(0, Math.min(1, root.progress))
                moveToStart: true
            }
        }
    }

    Lib.Icon {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: root.iconVerticalOffset
        width: root.iconSize
        height: root.iconSize
        name: root.iconName
        color: root.iconColor
    }
}
