import QtQuick

Rectangle {
    id: root

    property color base: Theme.surface
    property bool selected: false
    property bool cursor: false
    property bool hovered: false

    readonly property bool lightMode: Theme.mode === "light"
    readonly property color ink: lightMode ? "#23272B" : "#FAFAFA"

    radius: 9
    color: Qt.tint(base, selected ? (lightMode ? Theme.itemSelected : Qt.rgba(1, 1, 1, 0.10))
                       : cursor ? (lightMode ? Theme.itemCursor : Qt.rgba(1, 1, 1, 0.14))
                       : hovered ? (lightMode ? Theme.itemHover : Qt.rgba(1, 1, 1, 0.07))
                       : lightMode ? Theme.surface : Qt.alpha(ink, 0.045))
    border.width: (lightMode && selected) || (cursor && selected) ? 1 : 0
    border.color: lightMode && !cursor ? "#D3D5DA" : Qt.alpha(ink, 0.25)

    Behavior on color { ColorAnimation { duration: 140 } }
}
