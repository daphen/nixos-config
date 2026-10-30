import QtQuick

// The raised pill: the Cockpit's active session pill, for chips, tags and selected rows.
Item {
    id: root

    property real radius: height / 2
    property bool hovered: false
    readonly property bool lightMode: Theme.mode === "light"
    readonly property color contentColor: Theme.fg

    GradientFrame {
        objectName: "pillFrame"
        anchors.fill: parent
        visible: !root.lightMode
        radius: root.radius
        fill: Qt.tint(Qt.lighter(Theme.surface0, 1.25), Qt.rgba(1, 1, 1, 0.10))
        edge: "#FAFAFA"
    }
    LightKey {
        objectName: "pillKey"
        anchors.fill: parent
        visible: root.lightMode
        radius: root.radius
        outline: Qt.alpha("#23272B", 0.16)
    }
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Qt.alpha(Theme.fg, root.hovered ? 0.05 : 0)
        Behavior on color { ColorAnimation { duration: 120 } }
    }
}
