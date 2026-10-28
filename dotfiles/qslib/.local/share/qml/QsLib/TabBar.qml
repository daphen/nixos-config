import QtQuick

Item {
    id: root

    readonly property bool lightMode: Theme.mode === "light"
    readonly property color face: lightMode ? "#FDFDFD" : Qt.lighter(Theme.surface0, 1.2)
    readonly property int padding: 6

    implicitHeight: 46

    ContrastCard {
        anchors.fill: parent
        cardRadius: 15
        elevated: true
        bevelWidth: 1
        shadowColor: root.lightMode ? Qt.rgba(0.10, 0.12, 0.16, 0.10) : "#101010"
        outlineColor: root.lightMode ? "#D3D5DA" : "#363636"
        rimTop: root.lightMode ? "#E0E2E6" : "#333333"
        rimBottom: root.lightMode ? "#E0E2E6" : "#2C2C2C"
        faceTop: root.lightMode ? root.face : Qt.lighter(Theme.surface0, 1.25)
        faceUpper: faceTop
        faceMid: root.face
        faceBottom: root.face
    }
    LightKey {
        anchors.fill: parent
        visible: root.lightMode
        radius: 15
        outline: Qt.alpha(Theme.fg, 0.16)
        faceTop: root.face
        faceBottom: root.face
    }

    TapHandler {}
}
