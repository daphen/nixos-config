import QtQuick
import Quickshell

ShellRoot {
    FloatingWindow {
        id: preview
        title: "Quickshell login preview"
        visible: true
        implicitWidth: login.deckMode ? 1280 : 1440
        implicitHeight: login.deckMode ? 800 : 900
        color: "#050607"

        LoginView {
            id: login
            anchors.fill: parent
        }

        Row {
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 14
            }
            spacing: 8

            Repeater {
                model: [
                    { label: login.deckMode ? "LAPTOP" : "STEAM DECK", action: "device" },
                    { label: "REPLAY", action: "replay" },
                    { label: "UNLOCK", action: "unlock" },
                    { label: "ERROR", action: "error" }
                ]

                Rectangle {
                    required property var modelData
                    width: controlLabel.implicitWidth + 22
                    height: 30
                    radius: 15
                    color: Qt.rgba(0.02, 0.025, 0.03, 0.76)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.18)

                    Text {
                        id: controlLabel
                        anchors.centerIn: parent
                        text: parent.modelData.label
                        color: "#FFFFFF"
                        font.family: "Inter"
                        font.pixelSize: 11
                        font.weight: 600
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const action = parent.modelData.action
                            if (action === "device") login.deckMode = !login.deckMode
                            else if (action === "replay") login.playLock()
                            else if (action === "unlock") login.playUnlock()
                            else if (action === "error") login.showError()
                        }
                    }
                }
            }
        }
    }
}
