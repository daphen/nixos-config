import QtQuick
import QtQuick.Layouts
import "Modules" as Modules
import "QsLib" as Lib

Item {
    id: root

    property string authState: "idle"
    property bool unlocking: false

    signal passwordSubmitted(string password)

    function beginAuthentication() {
        if (!passwordInput.text.length || authState === "authenticating" || unlocking) return
        authState = "authenticating"
        passwordSubmitted(passwordInput.text)
    }

    function showError() {
        passwordInput.text = ""
        authState = "error"
        passwordInput.forceActiveFocus()
    }

    width: parent ? parent.width : 1280
    height: parent ? parent.height : 720
    opacity: unlocking ? 0 : 1
    scale: unlocking ? 0.97 : 1

    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    Rectangle {
        id: card
        width: Math.min(root.width - 40, 460)
        height: 208
        anchors.centerIn: parent
        radius: 28
        color: Modules.Theme.mode === "dark" ? Qt.rgba(0.055, 0.055, 0.055, 0.94) : Qt.rgba(0.97, 0.98, 0.99, 0.94)
        border.width: 1
        border.color: root.authState === "error" ? Modules.Theme.red : Modules.Theme.hairline

        Behavior on border.color { ColorAnimation { duration: 160 } }

        ColumnLayout {
            anchors { fill: parent; margins: 24 }
            spacing: 14

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    radius: 15
                    color: Modules.Theme.purple

                    Lib.Icon {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        name: "lock"
                        color: "#FFFFFF"
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        text: "David"
                        color: Modules.Theme.fg
                        font.family: Modules.Theme.fontFamily
                        font.pixelSize: 16
                        font.weight: 650
                    }

                    Text {
                        text: root.authState === "error" ? "That password didn’t work" : "Session locked"
                        color: root.authState === "error" ? Modules.Theme.red : Modules.Theme.fg_muted
                        font.family: Modules.Theme.fontFamily
                        font.pixelSize: 12
                        font.weight: Modules.Theme.fontWeight
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 58
                radius: Modules.Theme.radiusInner
                color: Modules.Theme.mode === "dark" ? "#171717" : "#ECEFF1"
                border.width: 2
                border.color: root.authState === "error" ? Modules.Theme.red : Modules.Theme.hairline

                RowLayout {
                    anchors { fill: parent; margins: 6 }
                    spacing: 8

                    TextInput {
                        id: passwordInput
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        leftPadding: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: Modules.Theme.fg
                        selectionColor: Modules.Theme.purple
                        selectedTextColor: Modules.Theme.fg
                        font.family: "Inter"
                        font.pixelSize: 16
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        enabled: root.authState !== "authenticating" && !root.unlocking
                        onTextEdited: {
                            if (root.authState === "error") root.authState = "idle"
                        }
                        onAccepted: root.beginAuthentication()

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            visible: !passwordInput.text.length
                            text: root.authState === "authenticating" ? "Checking…" : "Password"
                            color: Modules.Theme.fg_muted
                            font: passwordInput.font
                        }
                    }

                    Lib.PrimaryButton {
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 46
                        radius: Modules.Theme.radiusSm
                        primary: true
                        iconName: "arrow-door-in"
                        enabled: root.authState !== "authenticating" && !root.unlocking
                        onClicked: root.beginAuthentication()
                    }
                }
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Press Enter to unlock"
                color: Modules.Theme.fg_muted
                font.family: Modules.Theme.fontFamily
                font.pixelSize: 11
                font.weight: Modules.Theme.fontWeight
            }
        }
    }

    Component.onCompleted: passwordInput.forceActiveFocus()
}
