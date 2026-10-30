import QtQuick

Rectangle {
    id: root

    property color base: Theme.surface
    property bool selected: false
    property bool cursor: false
    property bool hovered: false

    readonly property bool lightMode: Theme.mode === "light"
    readonly property color ink: lightMode ? "#23272B" : "#FAFAFA"
    readonly property bool raised: selected || cursor

    radius: 9
    color: Qt.tint(base, lightMode ? (hovered ? Theme.itemHover : Theme.surface)
                       : selected ? Qt.rgba(1, 1, 1, 0.10)
                       : cursor ? Qt.rgba(1, 1, 1, 0.14)
                       : hovered ? Qt.rgba(1, 1, 1, 0.07)
                       : Qt.alpha(ink, 0.045))

    Behavior on color { ColorAnimation { duration: 140 } }

    GradientFrame {
        objectName: "tabFaceFrame"
        anchors.fill: parent
        visible: !root.lightMode && root.raised
        radius: root.radius
        fill: root.color
        edge: root.ink
        strength: root.cursor && root.selected ? 1.3 : 1
    }
    LightKey {
        objectName: "tabFaceKey"
        anchors.fill: parent
        visible: root.lightMode && root.raised
        radius: root.radius
        outline: Qt.alpha(root.ink, root.cursor && root.selected ? 0.24 : 0.16)
        faceTop: root.selected ? "#FDFDFD" : "#FBFBFB"
        faceBottom: root.selected ? "#F5F5F6" : "#F1F1F2"
    }
}
