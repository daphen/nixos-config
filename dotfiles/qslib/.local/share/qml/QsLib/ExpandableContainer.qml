import QtQuick

Rectangle {
    property bool expanded: false
    property real collapsedHeight: 44
    property real expandedHeight: 430
    property int animationDuration: 280

    height: expanded ? expandedHeight : collapsedHeight
    radius: 24
    clip: true

    Behavior on height {
        NumberAnimation {
            duration: animationDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.32, 0.72, 0.0, 1.0, 1.0, 1.0]
        }
    }
}
